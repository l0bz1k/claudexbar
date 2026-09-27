import Foundation
import ClaudexBarCore

/// Plain-text snapshot of everything useful for diagnosing a problem report:
/// versions, settings, what each provider last returned, auto-start state,
/// which CLIs were found, and the tail of the log.
///
/// Built to be pasted into a GitHub issue, so it never includes credentials:
/// the whole report goes through `SecretScanner`, and the home directory is
/// shortened to `~` so it doesn't leak the account name.
enum DiagnosticsReport {
    private static let logTailLines = 40

    static func make(
        settings: AppSettings,
        snapshots: [ProviderID: UsageSnapshot],
        errors: [ProviderID: UsageError],
        activeProvider: ProviderID,
        autoStarter: SessionAutoStarter,
        now: Date = Date()
    ) -> String {
        let iso = ISO8601DateFormatter()
        func date(_ value: Date?) -> String { value.map { iso.string(from: $0) } ?? "—" }

        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        lines.append("ClaudexBar diagnostics — \(date(now))")
        lines.append("App \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)")
        lines.append("")
        lines.append("## Settings")
        lines.append("enabled: \(settings.enabledProviders.map(\.rawValue).sorted().joined(separator: ", ")); active: \(activeProvider.rawValue)")
        lines.append("refresh: \(Int(settings.refreshInterval))s; percent: \(settings.percentMode.rawValue); pace warning: \(settings.paceWarningEnabled); smart switch: \(settings.smartSwitchEnabled)")
        lines.append("launch at login: \(LaunchAgentManager.isEnabled()); auto CLI updates: \(settings.automaticCLIUpdatesEnabled)")

        for provider in [ProviderID.claude, .codex] {
            lines.append("")
            lines.append("## \(provider.displayName)")
            lines.append("cli: \(CLIExecutableLocator.executable(for: provider)?.path ?? "not found")")
            if let error = errors[provider] {
                lines.append("last error: \(error)")
            }
            if let snapshot = snapshots[provider] {
                lines.append("fetched: \(date(snapshot.fetchedAt))")
                for (name, window) in [("primary", snapshot.primary), ("secondary", snapshot.secondary)] {
                    guard let window else {
                        lines.append("\(name): none")
                        continue
                    }
                    let duration = window.windowDuration.map { "\(Int($0))s" } ?? "?"
                    var line = "\(name): \(window.windowLabel) remaining \(window.remainingPercent)% reset \(date(window.resetAt)) duration \(duration)"
                    if let pace = UsageFormatter.pace(for: window, now: now) {
                        line += " pace-exhausts \(date(pace.projectedExhaustion))"
                    }
                    lines.append(line)
                }
            } else {
                lines.append("no snapshot yet")
            }

            let state = autoStarter.currentState(provider: provider)
            lines.append(
                "auto-start: enabled \(settings.autoStartEnabled(for: provider)); breaker \(state.circuitBroken) since \(date(state.circuitBrokenAt)); " +
                "unconfirmed \(state.consecutiveUnconfirmed); launch failures \(state.consecutiveLaunchFailures); " +
                "retry after \(date(state.retryNotBefore)); last attempt \(date(state.lastAttemptAt)); attempts/24h \(state.attemptsInLast24h.count)"
            )
        }

        lines.append("")
        lines.append("## Log (last \(logTailLines) lines)")
        SanitizedLogger.shared.flush()
        let logURL = AppPaths.logs.appendingPathComponent("claudexbar.log")
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            lines.append(contentsOf: text.split(separator: "\n").suffix(logTailLines).map(String.init))
        } else {
            lines.append("(no log)")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return SecretScanner.redact(lines.joined(separator: "\n"))
            .replacingOccurrences(of: home, with: "~")
    }
}
