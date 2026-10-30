import Foundation
import SQLite3

/// opencode's own free tier (OpenCode Zen free models, provider `opencode`).
///
/// There is no usage API: the server only says "Free usage limit reached" (HTTP
/// 429, `Retry-After: <seconds>`) when a request is refused. opencode stores
/// that response — headers included — in its local session database, so this
/// provider reads the most recent such refusal (read-only, no network) and
/// shows a countdown until `Date` + `Retry-After`. Outside a block it shows
/// "ok": how much free usage is left is never reported, and a made-up
/// percentage would be worse than none.
public struct OpenCodeFreeProvider: UsageProvider {
    public let id = ProviderID.opencodeFree
    public let displayName = ProviderID.opencodeFree.displayName

    private let databaseURL: URL
    private let now: @Sendable () -> Date

    public static var defaultDatabaseURL: URL {
        OpencodeKeyReader.defaultAuthURL.deletingLastPathComponent().appendingPathComponent("opencode.db")
    }

    public init(databaseURL: URL = OpenCodeFreeProvider.defaultDatabaseURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.databaseURL = databaseURL
        self.now = now
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("opencode", ["auth", "login"])
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .failure(.missingAuth) // opencode not installed / never run
        }
        guard let latest = Self.latestRefusal(databaseURL: databaseURL) else {
            return .failure(.decoding)
        }
        return .success(Self.snapshot(refusalJSON: latest.isEmpty ? nil : latest, now: now()))
    }

    /// The newest stored free-tier refusal, "" when there is none, nil when the
    /// database couldn't be read.
    public static func latestRefusal(databaseURL: URL) -> String? {
        var db: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = """
        SELECT data FROM message
        WHERE data LIKE '%"statusCode":429%' AND data LIKE '%Free usage%'
        ORDER BY time_created DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: text)
        case SQLITE_DONE:
            return ""
        default:
            return nil
        }
    }

    public static func snapshot(refusalJSON: String?, now: Date) -> UsageSnapshot {
        let resetAt = refusalJSON.flatMap { resetDate(fromRefusal: $0) }
        if let resetAt, resetAt > now {
            let window = UsageWindow(
                windowLabel: "free",
                remainingPercent: 0,
                resetAt: resetAt,
                title: "Free tier: limit reached — opencode's free models resume in \(UsageFormatter.resetLabel(resetAt: resetAt, now: now))"
            )
            return UsageSnapshot(primary: window, secondary: nil, fetchedAt: now)
        }
        let window = UsageWindow(
            windowLabel: "free",
            remainingPercent: 100,
            resetAt: nil,
            title: "Free tier: no limit hit (OpenCode doesn't report how much is left)",
            displayValue: "ok"
        )
        return UsageSnapshot(primary: window, secondary: nil, fetchedAt: now)
    }

    /// `Date` header (falling back to the message's completion time) plus
    /// `Retry-After` (seconds or an HTTP date). Only for opencode's own
    /// provider's 429s.
    public static func resetDate(fromRefusal json: String) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (root["providerID"] as? String).map({ $0 == "opencode" }) ?? true,
              let error = root["error"] as? [String: Any],
              let data = error["data"] as? [String: Any],
              (data["statusCode"] as? NSNumber)?.intValue == 429 else {
            return nil
        }
        let headers = (data["responseHeaders"] as? [String: Any] ?? [:])
            .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value as? String }

        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(identifier: "GMT")
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let completed = ((root["time"] as? [String: Any])?["completed"] as? NSNumber)
            ?? ((root["time"] as? [String: Any])?["created"] as? NSNumber)
        let base = headers["date"].flatMap(httpDate.date(from:))
            ?? completed.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }

        guard let retryAfter = headers["retry-after"] else { return nil }
        if let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return base?.addingTimeInterval(seconds)
        }
        return httpDate.date(from: retryAfter)
    }
}
