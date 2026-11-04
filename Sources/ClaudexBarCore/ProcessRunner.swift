import Foundation

/// Runs a subprocess with a hard timeout and continuously drained output.
///
/// Both properties matter for a background menu-bar app:
/// - Output is read *while* the child runs (via `readabilityHandler`), so a
///   chatty child can never fill the ~64 KB pipe buffer and block forever.
///   Only the last `outputLimit` bytes are kept.
/// - A timeout terminates (then SIGKILLs) a hung child, so a stuck CLI can't
///   wedge whatever is waiting on it — e.g. an update flag that would
///   otherwise stay "in progress" until the app is relaunched.
///
/// Output that arrives after the child exits (from a grandchild that inherited
/// the pipe) is deliberately ignored rather than awaited: waiting for EOF there
/// could block indefinitely.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
        public let launchFailed: Bool

        public var succeeded: Bool { exitCode == 0 && !timedOut && !launchFailed }

        /// A short, single-line, secret-redacted excerpt suitable for the log:
        /// the tail of stderr, or of stdout when stderr is empty.
        public func diagnosticExcerpt(maxLength: Int = 240) -> String {
            let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
            let oneLine = source
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            let tail = oneLine.count > maxLength ? "…" + oneLine.suffix(maxLength) : oneLine
            return SecretScanner.redact(tail)
        }
    }

    /// PATH for CLI subprocesses: the usual install locations first (launchd
    /// hands LaunchAgents a minimal PATH), then whatever we inherited.
    public static var cliEnvironment: [String: String] {
        // The same directories the CLIs are found in, so a CLI installed with
        // e.g. nvm also finds its `node`.
        let path = ExecutableResolver.searchDirectories().joined(separator: ":")
        return ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
    }

    /// SIGTERM to the process and everything it started (a CLI's workers
    /// would otherwise outlive it), SIGKILL to whatever is left 3 s later.
    static func terminateTree(_ process: Process) {
        let root = process.processIdentifier
        let tree = descendants(of: root) + [root]
        tree.forEach { kill($0, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            tree.forEach { pid in if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
    }

    /// All descendants of `pid`, deepest first.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = Int(proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
        for child in buffer.prefix(max(0, count)) where child > 0 {
            result += descendants(of: child) + [child]
        }
        return result
    }

    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        outputLimit: Int = 16 * 1024,
        stopWhen: (@Sendable () -> Bool)? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment ?? cliEnvironment
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = RunState(continuation: continuation, outputLimit: outputLimit)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                state.append(handle.availableData, toStderr: false)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                state.append(handle.availableData, toStderr: true)
            }

            process.terminationHandler = { finished in
                // Give already-buffered output a moment to be delivered, then
                // detach; see the type comment for why we don't await EOF.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    state.finish(exitCode: finished.terminationStatus)
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                state.finishLaunchFailure()
                return
            }

            // Optional early stop, checked once a second: for commands that
            // have said what they had to say but would otherwise keep waiting
            // (opencode 1.x retries a refused request for hours).
            if let stopWhen {
                @Sendable func poll() {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        guard process.isRunning else { return }
                        if stopWhen() {
                            terminateTree(process)
                        } else {
                            poll()
                        }
                    }
                }
                poll()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                terminateTree(process)
            }
        }
    }
}

/// Thread-safe accumulator shared by the pipe handlers, the termination
/// handler and the timeout watchdog; guarantees a single resume.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false
    private var resumed = false
    private let outputLimit: Int
    private let continuation: CheckedContinuation<ProcessRunner.Result, Never>

    init(continuation: CheckedContinuation<ProcessRunner.Result, Never>, outputLimit: Int) {
        self.continuation = continuation
        self.outputLimit = outputLimit
    }

    func append(_ data: Data, toStderr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if toStderr {
            stderr.append(data)
            if stderr.count > outputLimit { stderr = stderr.suffix(outputLimit) }
        } else {
            stdout.append(data)
            if stdout.count > outputLimit { stdout = stdout.suffix(outputLimit) }
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func finish(exitCode: Int32) {
        resume { stdout, stderr, timedOut in
            ProcessRunner.Result(exitCode: exitCode, stdout: stdout, stderr: stderr, timedOut: timedOut, launchFailed: false)
        }
    }

    func finishLaunchFailure() {
        resume { _, _, _ in
            ProcessRunner.Result(exitCode: 127, stdout: "", stderr: "", timedOut: false, launchFailed: true)
        }
    }

    private func resume(_ make: (String, String, Bool) -> ProcessRunner.Result) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        let result = make(
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self),
            timedOut
        )
        lock.unlock()
        continuation.resume(returning: result)
    }
}
