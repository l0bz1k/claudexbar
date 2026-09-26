import Foundation

enum AppPaths {
    static let applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudexBar", isDirectory: true)

    static let logs: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudexBar", isDirectory: true)

    static let launchAgent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.ipang.claudexbar.plist")

    static let cliUpdateLaunchAgent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.ipang.claudexbar.cli-updater.plist")

    /// Where `URLSession.shared` kept its on-disk response cache. Nothing
    /// uses it any more (see `URLSession.claudexbar`).
    static let legacyURLCache: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.ipang.claudexbar", isDirectory: true)

    /// Size above which a log file is rotated (app log) or truncated
    /// (launchd-captured stderr).
    static let maxLogBytes = 1_000_000

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    /// Launch-time cleanup:
    /// - Deletes the old URL cache. A corrupted `Cache.db` there made every
    ///   request log three SQLite errors, forever; it is never recreated now.
    /// - Truncates the stderr file launchd redirects into when it has grown
    ///   past `maxLogBytes`. launchd keeps that file open in append mode, so
    ///   truncating in place is safe and writes simply continue at the new end.
    static func housekeeping() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: legacyURLCache.path) {
            try? fileManager.removeItem(at: legacyURLCache)
        }
        for name in ["claudexbar.err.log", "claudexbar.out.log"] {
            let url = logs.appendingPathComponent(name)
            if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxLogBytes {
                truncate(url.path, 0)
            }
        }
    }
}
