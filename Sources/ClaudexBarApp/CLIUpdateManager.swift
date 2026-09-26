import Foundation
import ClaudexBarCore

struct CLICommandResult: Sendable {
    let provider: ProviderID
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

enum CLIExecutableLocator {
    static func executable(for provider: ProviderID) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        switch provider {
        case .claude:
            candidates = [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .codex:
            candidates = [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex"
            ]
        }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

actor CLIUpdateManager {
    static let shared = CLIUpdateManager()

    private var updateInProgress = false

    func snapshot() async -> CLIUpdateSnapshot {
        async let installed = installedVersions()
        async let latest = CLILatestVersionChecker().fetchLatestVersions()
        return await CLIUpdateSnapshot(installed: installed, latest: latest)
    }

    func updateAll() async -> [CLICommandResult] {
        guard !updateInProgress else { return [] }
        updateInProgress = true
        defer { updateInProgress = false }

        var results: [CLICommandResult] = []
        for provider in ProviderID.allCases {
            guard let executable = CLIExecutableLocator.executable(for: provider) else {
                results.append(CLICommandResult(provider: provider, exitCode: 127))
                continue
            }
            results.append(await run(executable: executable, arguments: ["update"], provider: provider))
        }
        return results
    }

    private func installedVersions() async -> [ProviderID: String] {
        await withTaskGroup(of: (ProviderID, String?).self) { group in
            for provider in ProviderID.allCases {
                group.addTask {
                    guard let executable = CLIExecutableLocator.executable(for: provider) else {
                        return (provider, nil)
                    }
                    return (provider, await Self.version(executable: executable))
                }
            }

            var versions: [ProviderID: String] = [:]
            for await (provider, version) in group {
                versions[provider] = version
            }
            return versions
        }
    }

    private static func version(executable: URL) async -> String? {
        let result = await ProcessRunner.run(executable: executable, arguments: ["--version"], timeout: 30)
        guard result.succeeded else { return nil }
        return CLIVersionParser.semanticVersion(in: result.stdout + result.stderr)
    }

    private func run(executable: URL, arguments: [String], provider: ProviderID) async -> CLICommandResult {
        // A generous but finite ceiling: an update may download a sizeable
        // binary, but a hung one must not hold `updateInProgress` forever.
        let result = await ProcessRunner.run(executable: executable, arguments: arguments, timeout: 10 * 60)
        let outcome: String
        if result.succeeded {
            outcome = "ok"
        } else if result.timedOut {
            outcome = "failed: timed out"
        } else {
            outcome = "failed exit=\(result.exitCode): \(result.diagnosticExcerpt())"
        }
        SanitizedLogger.shared.log(provider: provider, message: "cli update \(outcome)")
        return CLICommandResult(provider: provider, exitCode: result.timedOut ? 124 : result.exitCode)
    }
}

enum CLIUpdateScheduler {
    private static let queue = DispatchQueue(label: "ClaudexBar.CLIUpdateScheduler", qos: .utility)

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.cliUpdateLaunchAgent.path)
    }

    static func setEnabled(_ enabled: Bool) {
        queue.async {
            enabled ? install() : uninstall()
        }
    }

    private static func install() {
        guard let executable = Bundle.main.executableURL else { return }
        AppPaths.ensureDirectories()
        try? FileManager.default.createDirectory(
            at: AppPaths.cliUpdateLaunchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": "com.ipang.claudexbar.cli-updater",
            "ProgramArguments": [executable.path, "--update-clis"],
            "StartCalendarInterval": ["Hour": 10, "Minute": 17],
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "EnvironmentVariables": [
                "PATH": [
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin"
                ].joined(separator: ":")
            ],
            "StandardOutPath": AppPaths.logs.appendingPathComponent("cli-updater.out.log").path,
            "StandardErrorPath": AppPaths.logs.appendingPathComponent("cli-updater.err.log").path
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else { return }

        runLaunchctl(["bootout", "gui/\(getuid())", AppPaths.cliUpdateLaunchAgent.path])
        try? data.write(to: AppPaths.cliUpdateLaunchAgent, options: .atomic)
        runLaunchctl(["bootstrap", "gui/\(getuid())", AppPaths.cliUpdateLaunchAgent.path])
    }

    private static func uninstall() {
        runLaunchctl(["bootout", "gui/\(getuid())", AppPaths.cliUpdateLaunchAgent.path])
        try? FileManager.default.removeItem(at: AppPaths.cliUpdateLaunchAgent)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
