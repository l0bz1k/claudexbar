import Foundation

/// Turns the providers' raw plan identifiers into the short label shown after
/// the provider's name ("Claude Code Pro", "Codex Go").
public enum PlanLabels {
    /// Codex usage response: `plan_type` ("go", "plus", "pro", "prolite", …).
    public static func codex(fromUsage data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["plan_type"] as? String else { return nil }
        return codex(raw)
    }

    public static func codex(_ raw: String) -> String? {
        let known = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
                     "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        let key = raw.lowercased()
        guard !key.isEmpty, key != "unknown" else { return nil }
        return known[key] ?? key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    /// Claude `/api/oauth/profile`: `organization.organization_type`
    /// ("claude_pro", "claude_max", "claude_team", "claude_enterprise") and,
    /// for Max, the tier in `organization.rate_limit_tier` ("…_max_5x").
    public static func claude(fromProfile data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let org = root["organization"] as? [String: Any]
        let account = root["account"] as? [String: Any]
        return claude(
            organizationType: org?["organization_type"] as? String,
            rateLimitTier: org?["rate_limit_tier"] as? String,
            hasMax: account?["has_claude_max"] as? Bool ?? false,
            hasPro: account?["has_claude_pro"] as? Bool ?? false
        )
    }

    public static func claude(organizationType: String?, rateLimitTier: String?, hasMax: Bool = false, hasPro: Bool = false) -> String? {
        let tier = (rateLimitTier ?? "").lowercased()
        switch organizationType?.lowercased() {
        case "claude_max":
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default:
            if hasMax { return "Max" }
            if hasPro { return "Pro" }
            return nil
        }
    }
}

/// The last plan label fetched, reused for a while: plans change rarely.
final class PlanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var label: String?
    private var fetchedAt = Date.distantPast
    private let maxAge: TimeInterval = 6 * 60 * 60

    func fresh(now: Date = Date()) -> String?? {
        lock.withLock { now.timeIntervalSince(fetchedAt) < maxAge ? .some(label) : .none }
    }

    var last: String? { lock.withLock { label } }

    func store(_ label: String?, now: Date = Date()) {
        lock.withLock {
            if let label { self.label = label }
            fetchedAt = now
        }
    }
}
