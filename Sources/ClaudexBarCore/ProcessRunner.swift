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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = (preferred + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        return ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
    }

    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval,
        outputLimit: Int = 16 * 1024
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

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
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
