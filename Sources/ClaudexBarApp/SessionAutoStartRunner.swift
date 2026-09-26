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
        case launchFailed
        case timedOut
        case nonZeroExit(Int32, detail: String)

        var description: String {
            switch self {
            case .executableNotFound: return "executable_not_found"
            case .launchFailed: return "launch_failed"
            case .timedOut: return "timed_out"
            case .nonZeroExit(let code, let detail):
                return detail.isEmpty ? "exit_\(code)" : "exit_\(code): \(detail)"
            }
        }
    }

    private static let anchorPrompt = "Reply with just: OK"
    private static let processTimeout: TimeInterval = 60

    static func run(provider: ProviderID) async -> Result<Void, RunError> {
        guard let executable = CLIExecutableLocator.executable(for: provider) else {
            return .failure(.executableNotFound)
        }
        let scratch = scratchDirectory()
        let arguments: [String]
        switch provider {
        case .claude:
            arguments = [
                "-p", anchorPrompt,
                "--model", "haiku",
                "--restricted",
                "--output-format", "json"
            ]
        case .codex:
            arguments = [
                "exec", anchorPrompt,
                "--sandbox", "read-only",
                "--ephemeral",
                "--skip-git-repo-check",
                "-C", scratch.path
            ]
        }

        let result = await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: scratch,
            timeout: processTimeout
        )
        if result.launchFailed { return .failure(.launchFailed) }
        if result.timedOut { return .failure(.timedOut) }
        guard result.exitCode == 0 else {
            return .failure(.nonZeroExit(result.exitCode, detail: result.diagnosticExcerpt()))
        }
        return .success(())
    }

    /// A dedicated, empty scratch directory: keeps CLAUDE.md/AGENTS.md
    /// project-context auto-discovery from pulling in anything real, and
    /// keeps this call visibly separate from the user's actual project work.
    private static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudexBar-AutoStart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
