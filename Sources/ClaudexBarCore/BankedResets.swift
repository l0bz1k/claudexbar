import Foundation

/// A rate-limit reset you've been granted and can apply yourself later (Codex
/// "rate limit reset credits", Claude "limit resets"). Applying one brings the
/// limit back to 100% on the spot.
public struct BankedReset: Equatable, Sendable {
    public let title: String?
    public let expiresAt: Date?
    /// Whether the provider says it can be applied right now (nil = not stated).
    public let usableNow: Bool?

    public init(title: String?, expiresAt: Date?, usableNow: Bool? = nil) {
        self.title = title
        self.expiresAt = expiresAt
        self.usableNow = usableNow
    }
}

public struct BankedResets: Equatable, Sendable {
    /// How many resets are available. Can exceed `items.count` when only the
    /// count is known (Codex sends details from a separate call).
    public let count: Int
    public let items: [BankedReset]

    public init(count: Int, items: [BankedReset]) {
        self.count = count
        self.items = items
    }

    /// The deadline that matters most: the earliest expiry.
    public var nextExpiry: Date? { items.compactMap(\.expiresAt).min() }
}

/// Reads banked resets from provider responses. Kept apart from the usage
/// decoders and deliberately tolerant: an unexpected shape here must never
/// break the limits themselves — at worst the resets just don't show.
///
/// The redemption `id` each entry carries is never read: it is the handle that
/// *spends* a reset, and nothing in this app should hold it.
public enum BankedResetParser {
    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter.parseClaudexDate(text) { return date }
        // Microsecond precision ("…02.587718Z", "…+00:00") isn't accepted by
        // every ISO 8601 parser; retry with the fraction trimmed.
        if let dot = text.firstIndex(of: ".") {
            let tail = text[dot...].drop(while: { $0 == "." || $0.isNumber })
            return ISO8601DateFormatter.parseClaudexDate(String(text[..<dot]) + tail)
        }
        return nil
    }

    /// Codex usage response: `rate_limit_reset_credits.available_count`.
    public static func codexCount(_ usage: Data) -> Int? {
        guard let block = json(usage)?["rate_limit_reset_credits"] as? [String: Any] else { return nil }
        return int(block["available_count"])
    }

    /// Codex `/wham/rate-limit-reset-credits`: only `status == "available"`
    /// entries are resets you still have.
    public static func codexDetails(_ data: Data) -> [BankedReset]? {
        guard let root = json(data), let credits = root["credits"] as? [[String: Any]] else { return nil }
        return credits
            .filter { ($0["status"] as? String) == "available" }
            .map {
                BankedReset(
                    title: $0["title"] as? String,
                    expiresAt: date($0["expires_at"]),
                    usableNow: nil // `is_supported_by_plan` means "your plan allows it", not "usable now"
                )
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// Claude usage response with `?cedar_ember=1`: the `cedar_ember` block.
    /// Absent, null or `eligible: false` all mean "nothing to show".
    public static func claude(_ usage: Data) -> BankedResets? {
        guard let block = json(usage)?["cedar_ember"] as? [String: Any],
              (block["eligible"] as? Bool) == true,
              let grants = block["grants"] as? [[String: Any]] else { return nil }
        var count = 0
        var items: [BankedReset] = []
        for grant in grants {
            let left = int(grant["resets_left"]) ?? 0
            guard left > 0, (grant["paused"] as? Bool) != true else { continue }
            count += left
            let reset = BankedReset(
                title: grant["label"] as? String,
                expiresAt: date(grant["ends_at"]),
                usableNow: grant["usable_now"] as? Bool
            )
            items.append(contentsOf: Array(repeating: reset, count: left))
        }
        guard count > 0 else { return nil }
        return BankedResets(count: count, items: items.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) })
    }
}

extension UsageSnapshot {
    public func withResets(_ resets: BankedResets?) -> UsageSnapshot {
        UsageSnapshot(primary: primary, secondary: secondary, fetchedAt: fetchedAt, extraWindows: extraWindows, resets: resets)
    }
}

extension UsageFormatter {
    /// "2 resets · until 6 Nov 23:44, 30 Nov 20:53".
    public static func resetsSummary(_ resets: BankedResets, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM HH:mm"
        let noun = resets.count == 1 ? "reset" : "resets"
        let dates = resets.items.compactMap(\.expiresAt).map(formatter.string(from:))
        return dates.isEmpty ? "\(resets.count) \(noun)" : "\(resets.count) \(noun) · until \(dates.joined(separator: ", "))"
    }
}
