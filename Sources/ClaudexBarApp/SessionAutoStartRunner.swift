import Foundation
import ClaudexBarCore

/// Sends one trivial, tool-free message through the **real** `claude`/`codex`
/// CLI binary the user already has installed and signed into — not a raw API
/// call. This is deliberate: it's functionally identical to the user typing
/// a message themselves, so it inherits whatever the official client already
/// does correctly to anchor a rate-limit window, and carries none of the
/// "is this OAuth token even scoped for the public API" uncertainty a direct
/// HTTP call would.
enum SessionAutoStartRunner {
    enum RunError: Error, CustomStringConvertible {
        case executableNotFound
        case timedOut
        case nonZeroExit(Int32)
        case launchFailed

        var description: String {
            switch self {
            case .executableNotFound: return "executable_not_found"
            case .timedOut: return "timed_out"
            case .nonZeroExit(let code): return "exit_\(code)"
            case .launchFailed: return "launch_failed"
            }
        }
    }

    private static let anchorPrompt = "Reply with just: OK"
    private static let processTimeout: TimeInterval = 45

    static func run(provider: ProviderID) async -> Result<Void, RunError> {
        switch provider {
        case .claude: return await runClaude()
        case .codex: return await runCodex()
        }
    }

    private static func runClaude() async -> Result<Void, RunError> {
        guard let executable = firstExecutable([
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]) else {
            return .failure(.executableNotFound)
        }
        return await runProcess(
            executable: executable,
            arguments: [
                "-p", anchorPrompt,
                "--model", "haiku",
                "--restricted",
                "--output-format", "json"
            ],
            workingDirectory: scratchDirectory()
        )
    }

    private static func runCodex() async -> Result<Void, RunError> {
        guard let executable = firstExecutable([
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]) else {
            return .failure(.executableNotFound)
        }
        let scratch = scratchDirectory()
        return await runProcess(
            executable: executable,
            arguments: [
                "exec", anchorPrompt,
                "--sandbox", "read-only",
                "--ephemeral",
                "--skip-git-repo-check",
                "-C", scratch.path
            ],
            workingDirectory: scratch
        )
    }

    /// A dedicated, empty scratch directory: keeps CLAUDE.md/AGENTS.md
    /// project-context auto-discovery from pulling in anything real, and
    /// keeps this call visibly separate from the user's actual project work.
    private static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudexBar-AutoStart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL
    ) async -> Result<Void, RunError> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            let resumeBox = SingleResumeBox(continuation: continuation)

            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    resumeBox.resume(.success(()))
                } else {
                    resumeBox.resume(.failure(.nonZeroExit(finished.terminationStatus)))
                }
            }

            do {
                try process.run()
            } catch {
                resumeBox.resume(.failure(.launchFailed))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + processTimeout) {
                if process.isRunning {
                    process.terminate()
                    resumeBox.resume(.failure(.timedOut))
                }
            }
        }
    }
}

/// Guards a `CheckedContinuation` against double-resume when both the
/// termination handler and the timeout watchdog could fire.
private final class SingleResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Result<Void, SessionAutoStartRunner.RunError>, Never>

    init(continuation: CheckedContinuation<Result<Void, SessionAutoStartRunner.RunError>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, SessionAutoStartRunner.RunError>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}
