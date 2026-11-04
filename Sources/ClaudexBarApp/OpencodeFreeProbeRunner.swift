import Foundation
import ClaudexBarCore

/// Runs the OpenCode Free availability check (see `OpencodeFreeProbe`) with
/// the installed `opencode`, in ClaudexBar's own clean profile.
enum OpencodeFreeProbeRunner {
    private static var environment: [String: String] {
        OpencodeFreeProbe.environment(base: ProcessRunner.cliEnvironment)
    }

    private static var workDirectory: URL {
        OpencodeFreeProbe.directory.appendingPathComponent("work")
    }

    /// Creates the profile and keeps its config current.
    static func prepare() {
        let fileManager = FileManager.default
        let configDir = OpencodeFreeProbe.directory.appendingPathComponent("config/opencode")
        for dir in [configDir, OpencodeFreeProbe.dataDirectory, workDirectory,
                    OpencodeFreeProbe.directory.appendingPathComponent("cache"),
                    OpencodeFreeProbe.directory.appendingPathComponent("state")] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let config = configDir.appendingPathComponent("opencode.json")
        if (try? String(contentsOf: config, encoding: .utf8)) != OpencodeFreeProbe.config {
            try? OpencodeFreeProbe.config.write(to: config, atomically: true, encoding: .utf8)
        }
        // Keep the profile small: its history is never needed beyond a check.
        if OpencodeFreeProbe.size(of: OpencodeFreeProbe.databaseURL) > 20_000_000 {
            try? fileManager.removeItem(at: OpencodeFreeProbe.dataDirectory.appendingPathComponent("opencode/opencode.db"))
        }
        // Bound the log too, keeping its recent end (the latest refusals per
        // model live there). Safe: opencode isn't running between checks.
        let log = OpencodeFreeProbe.logURL
        if OpencodeFreeProbe.size(of: log) > 2_000_000 {
            let keep = OpencodeFreeProbe.contents(of: log, after: OpencodeFreeProbe.size(of: log) - 256_000)
            let lines = keep.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() // drop the partial first line
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
    }

    /// The free models the installed opencode currently lists.
    static func catalog(executable: URL) async -> [String] {
        prepare()
        let result = await ProcessRunner.run(
            executable: executable,
            arguments: ["models", "opencode", "--verbose"],
            environment: environment,
            workingDirectory: workDirectory,
            timeout: 60,
            outputLimit: 2 * 1024 * 1024
        )
        let models = OpencodeFreeProbe.freeModels(fromCatalog: result.stdout)
        if !models.isEmpty { OpencodeFreeProbe.saveCatalog(models) }
        return models
    }

    /// Asks one free model once. Stops opencode as soon as its log has the
    /// server's answer — opencode 1.x would otherwise retry a refusal for hours.
    static func probe(executable: URL, model: String) async -> OpencodeFreeProbe.Outcome {
        prepare()
        let logURL = OpencodeFreeProbe.logURL
        let offset = OpencodeFreeProbe.size(of: logURL)
        let result = await ProcessRunner.run(
            executable: executable,
            // --pure: no external plugins even if some reach the clean profile.
            arguments: ["run", "--pure", "--model", "opencode/\(model)", OpencodeFreeProbe.prompt],
            environment: environment,
            workingDirectory: workDirectory,
            timeout: 120,
            stopWhen: { OpencodeFreeProbe.logHasVerdict(OpencodeFreeProbe.contents(of: logURL, after: offset)) }
        )
        let newLog = OpencodeFreeProbe.contents(of: logURL, after: offset)
        return OpencodeFreeProbe.classify(newLog: newLog, stdout: result.stdout, exitCode: result.exitCode)
    }
}
