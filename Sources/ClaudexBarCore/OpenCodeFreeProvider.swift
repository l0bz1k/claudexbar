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
    private let logURL: URL
    private let now: @Sendable () -> Date

    public static var defaultDatabaseURL: URL {
        OpencodeKeyReader.defaultAuthURL.deletingLastPathComponent().appendingPathComponent("opencode.db")
    }

    public static var defaultLogURL: URL {
        OpencodeKeyReader.defaultAuthURL.deletingLastPathComponent().appendingPathComponent("log/opencode.log")
    }

    public init(
        databaseURL: URL = OpenCodeFreeProvider.defaultDatabaseURL,
        logURL: URL = OpenCodeFreeProvider.defaultLogURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseURL = databaseURL
        self.logURL = logURL
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
        // While opencode is still waiting to retry, the refusal exists only in
        // its log (and in memory): nothing reaches the database until it gives
        // up. Check whether a free-model answer has succeeded since then.
        let liveRefusal = Self.latestLoggedRefusal(logURL: logURL)
        let succeeded = liveRefusal.map { Self.freeModelSucceeded(since: $0, databaseURL: databaseURL) } ?? false
        return .success(Self.snapshot(
            refusalJSON: latest.isEmpty ? nil : latest,
            loggedRefusalAt: succeeded ? nil : liveRefusal,
            now: now()
        ))
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

    /// How long an unconfirmed (log-only) block is assumed to last at most.
    /// Free-tier waits seen so far are 5-17 h.
    static let unconfirmedBlockLimit: TimeInterval = 24 * 60 * 60
    /// How long a logged refusal still counts as "blocked now". Apps that keep
    /// retrying (opencode v1 every ~10 min) keep refreshing it.
    static let refusalEvidenceWindow: TimeInterval = 60 * 60

    public static func snapshot(refusalJSON: String?, loggedRefusalAt: Date? = nil, now: Date) -> UsageSnapshot {
        let resetAt = refusalJSON.flatMap { resetDate(fromRefusal: $0) }
        if resetAt.map({ $0 <= now }) ?? true,
           let blockedAt = loggedRefusalAt,
           blockedAt <= now, now.timeIntervalSince(blockedAt) < unconfirmedBlockLimit {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            // A refusal is only evidence for a while: the server says nothing
            // until something asks again, and the limit can lift hours before
            // anyone does. Past that, say "unknown" rather than a stale 0%.
            if now.timeIntervalSince(blockedAt) >= refusalEvidenceWindow {
                let window = UsageWindow(
                    windowLabel: "free",
                    remainingPercent: 100,
                    resetAt: nil,
                    title: "Free tier: last refused at \(clock.string(from: blockedAt)), nothing tried since — the limit may have reset; the next request will tell",
                    displayValue: "?"
                )
                return UsageSnapshot(primary: window, secondary: nil, fetchedAt: now)
            }
            let window = UsageWindow(
                windowLabel: "free",
                remainingPercent: 0,
                resetAt: nil,
                title: "Free tier: limit reached at \(clock.string(from: blockedAt)) — opencode is waiting to retry; it hasn't recorded when the limit resets yet"
            )
            return UsageSnapshot(primary: window, secondary: nil, fetchedAt: now)
        }
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

    /// The newest free-tier refusal opencode logged ("stream error … Free usage
    /// limit reached" for provider `opencode`), read from the end of its log.
    public static func latestLoggedRefusal(logURL: URL, tailBytes: Int = 1_000_000) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n").reversed()
        // opencode truncates long log lines ("…Free usage limit reac"), so match the
        // stable prefix of both its phrasings ("limit reached", "exceeded").
        where line.contains("Free usage") && line.contains("stream error") && line.contains("providerID=opencode ") {
            guard let range = line.range(of: "timestamp=") else { continue }
            let stamp = line[range.upperBound...].prefix { $0 != " " }
            if let date = iso.date(from: String(stamp)) ?? ISO8601DateFormatter().date(from: String(stamp)) {
                return date
            }
        }
        return nil
    }

    /// Whether a free-tier ("opencode" provider) answer completed without an
    /// error after `date` — proof the block has lifted.
    public static func freeModelSucceeded(since date: Date, databaseURL: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(databaseURL.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = """
        SELECT 1 FROM message
        WHERE time_created > ?
          AND json_extract(data, '$.role') = 'assistant'
          AND json_extract(data, '$.providerID') = 'opencode'
          AND json_extract(data, '$.time.completed') IS NOT NULL
          AND json_extract(data, '$.error') IS NULL
          AND COALESCE(json_extract(data, '$.tokens.output'), 0) > 0
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 * 1000))
        return sqlite3_step(statement) == SQLITE_ROW
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
