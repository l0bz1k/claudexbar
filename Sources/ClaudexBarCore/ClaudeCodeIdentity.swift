import Foundation

/// How requests to Claude's usage endpoint identify themselves. The endpoint
/// only reports banked limit resets ("cedar_ember") to Claude Code itself — to
/// any other client it answers `eligible: false, ineligible_reason: "surface"`,
/// and to an old Claude Code `"cli_version"`. ClaudexBar reads the same
/// account with Claude Code's own sign-in, so it identifies as the installed
/// Claude Code (`claude-cli/<version> (external, cli)`, as the CLI does).
public enum ClaudeCodeIdentity {
    /// Used until the installed version is known, or without Claude Code
    /// installed (signed in through ClaudexBar only).
    public static let fallbackVersion = "2.1.322"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: String?

    /// The installed `claude --version`, set by the app at launch and after
    /// CLI updates.
    public static var installedVersion: String? {
        get { lock.withLock { installed } }
        set { lock.withLock { installed = newValue } }
    }

    public static func userAgent(version: String? = installedVersion) -> String {
        "claude-cli/\(version ?? fallbackVersion) (external, cli)"
    }
}
