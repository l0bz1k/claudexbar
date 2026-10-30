import Foundation

/// Reads API keys the way opencode stores them: `auth.json` in opencode's
/// data directory (`$XDG_DATA_HOME/opencode`, default `~/.local/share/opencode`),
/// keyed by provider id — `{"openrouter": {"type": "api", "key": "…"}}`.
/// An environment variable, when set, wins.
public struct OpencodeKeyReader: Sendable {
    private let authURL: URL
    private let environment: [String: String]

    public static var defaultAuthURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let dataHome = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return dataHome.appendingPathComponent("opencode/auth.json")
    }

    public init(authURL: URL = OpencodeKeyReader.defaultAuthURL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.authURL = authURL
        self.environment = environment
    }

    public func key(provider: String, environmentVariable: String) -> String? {
        if let value = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[provider] as? [String: Any],
              let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }
}

/// Shared HTTP plumbing for the API-key providers.
enum APIKeyRequest {
    static func get(_ url: URL, key: String, httpClient: any HTTPClient) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return try await httpClient.data(for: request)
    }

    static func error(for response: HTTPResponse) -> UsageError? {
        switch response.statusCode {
        case 200..<300: return nil
        case 401: return .authExpired
        case 429: return .rateLimited
        default:
            return EdgeBlockDetector.blockError(statusCode: response.statusCode, body: response.data)
                ?? .server(statusCode: response.statusCode)
        }
    }
}

private func number(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

private func money(_ dollars: Double) -> String {
    dollars >= 100 ? String(format: "$%.0f", dollars) : String(format: "$%.2f", dollars)
}

// MARK: - OpenRouter

/// OpenRouter, as used by opencode: the free-model daily request quota
/// (`/api/v1/key` → `free_model_daily_requests`, resets at 00:00 UTC) and the
/// prepaid credit balance (`/api/v1/credits`) — or the key's own spending
/// limit, when one is set.
public struct OpenRouterProvider: UsageProvider {
    public let id = ProviderID.openrouter
    public let displayName = ProviderID.openrouter.displayName

    private let keyReader: OpencodeKeyReader
    private let httpClient: any HTTPClient
    private let now: @Sendable () -> Date
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    public init(
        keyReader: OpencodeKeyReader = OpencodeKeyReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keyReader = keyReader
        self.httpClient = httpClient
        self.now = now
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("opencode", ["auth", "login"])
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        guard let key = keyReader.key(provider: "openrouter", environmentVariable: "OPENROUTER_API_KEY") else {
            return .failure(.missingAuth)
        }
        do {
            let keyResponse = try await APIKeyRequest.get(baseURL.appendingPathComponent("key"), key: key, httpClient: httpClient)
            if let error = APIKeyRequest.error(for: keyResponse) { return .failure(error) }
            // The balance is a nice-to-have: if it fails, still show the quota.
            let credits = try? await APIKeyRequest.get(baseURL.appendingPathComponent("credits"), key: key, httpClient: httpClient)
            let creditsData = credits.flatMap { (200..<300).contains($0.statusCode) ? $0.data : nil }
            return .success(try Self.parseUsage(key: keyResponse.data, credits: creditsData, now: now()))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.network)
        }
    }

    public static func parseUsage(key keyData: Data, credits creditsData: Data?, now: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            throw UsageError.decoding
        }

        var primary: UsageWindow?
        if let free = data["free_model_daily_requests"] as? [String: Any],
           let limit = number(free["limit"]), limit > 0 {
            let remaining = number(free["remaining"]) ?? max(0, limit - (number(free["used"]) ?? 0))
            primary = UsageWindow(
                windowLabel: "1d",
                remainingPercent: Int((remaining / limit * 100).rounded(.down)),
                resetAt: nextUTCMidnight(after: now),
                windowDuration: 24 * 60 * 60,
                title: "Free-model requests today (\(Int(remaining)) of \(Int(limit)) left)"
            )
        }

        var secondary: UsageWindow?
        if let limit = number(data["limit"]), limit > 0 {
            let remaining = number(data["limit_remaining"]) ?? max(0, limit - (number(data["usage"]) ?? 0))
            secondary = UsageWindow(
                windowLabel: money(remaining),
                remainingPercent: Int((remaining / limit * 100).rounded(.down)),
                resetAt: nil,
                title: "Key spending limit (\(money(remaining)) of \(money(limit)) left)"
            )
        } else if let creditsData,
                  let creditsRoot = try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any],
                  let credits = creditsRoot["data"] as? [String: Any],
                  let total = number(credits["total_credits"]), total > 0 {
            let balance = max(0, total - (number(credits["total_usage"]) ?? 0))
            secondary = UsageWindow(
                windowLabel: money(balance),
                remainingPercent: Int((balance / total * 100).rounded(.down)),
                resetAt: nil,
                title: "Credit balance (\(money(balance)) of \(money(total)))"
            )
        }

        guard primary != nil || secondary != nil else { throw UsageError.decoding }
        return UsageSnapshot(primary: primary, secondary: secondary, fetchedAt: now)
    }

    static func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    }
}

// MARK: - OpenCode Go

/// The OpenCode Go subscription: three dollar-denominated windows (rolling
/// 5 h, weekly, monthly) from `GET https://opencode.ai/zen/go/v1/usage`,
/// authorised with the Go API key.
///
/// Parsing is deliberately tolerant: the documented shape is
/// `{"usage": {"rolling": {"percent", "resetsAt"}, "weekly": …, "monthly": …}}`
/// (also seen with a capitalised `Usage` root), and `rollingUsage` /
/// `weeklyUsage` / `monthlyUsage` keys and second-based reset fields have been
/// mentioned too. `percent` is the share *used*.
public struct OpenCodeGoProvider: UsageProvider {
    public let id = ProviderID.opencodeGo
    public let displayName = ProviderID.opencodeGo.displayName

    private let keyReader: OpencodeKeyReader
    private let httpClient: any HTTPClient
    private let now: @Sendable () -> Date
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    public init(
        keyReader: OpencodeKeyReader = OpencodeKeyReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keyReader = keyReader
        self.httpClient = httpClient
        self.now = now
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("opencode", ["auth", "login"])
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        guard let key = keyReader.key(provider: "opencode-go", environmentVariable: "OPENCODE_API_KEY") else {
            return .failure(.missingAuth)
        }
        do {
            let response = try await APIKeyRequest.get(usageURL, key: key, httpClient: httpClient)
            if let error = APIKeyRequest.error(for: response) { return .failure(error) }
            return .success(try Self.parseUsage(response.data, now: now()))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.network)
        }
    }

    public static func parseUsage(_ data: Data, now: Date) throws -> UsageSnapshot {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding
        }
        let root = (top["usage"] as? [String: Any]) ?? (top["Usage"] as? [String: Any]) ?? top

        func window(_ names: [String], label: String, title: String, duration: TimeInterval) -> UsageWindow? {
            guard let raw = names.lazy.compactMap({ root[$0] as? [String: Any] }).first,
                  let used = number(raw["percent"]) ?? number(raw["usagePercent"]) ?? number(raw["usedPercent"]) else {
                return nil
            }
            var resetAt = ["resetsAt", "resetAt"].lazy
                .compactMap { raw[$0] as? String }
                .compactMap { ISO8601DateFormatter.parseClaudexDate($0) }
                .first
            if resetAt == nil,
               let seconds = ["resetInSec", "resetInSeconds", "resetsInSeconds", "resetIn"].lazy.compactMap({ number(raw[$0]) }).first {
                resetAt = now.addingTimeInterval(seconds)
            }
            return UsageWindow(
                windowLabel: label,
                remainingPercent: Int((100 - used).rounded(.down)),
                resetAt: resetAt,
                windowDuration: duration,
                title: title
            )
        }

        let rolling = window(["rolling", "rollingUsage"], label: "5h", title: "5-hour limit", duration: 5 * 60 * 60)
        let weekly = window(["weekly", "weeklyUsage"], label: "7d", title: "Weekly limit", duration: 7 * 24 * 60 * 60)
        let monthly = window(["monthly", "monthlyUsage"], label: "30d", title: "Monthly limit", duration: 30 * 24 * 60 * 60)
        guard rolling != nil || weekly != nil || monthly != nil else { throw UsageError.decoding }

        // Two tray columns, three limits: the second column shows whichever of
        // weekly/monthly is closer to running out; the other goes to the tooltip.
        let longer = [weekly, monthly].compactMap { $0 }
        let tightest = longer.min { $0.remainingPercent < $1.remainingPercent }
        let others = longer.filter { $0 != tightest }
        return UsageSnapshot(primary: rolling, secondary: tightest, fetchedAt: now, extraWindows: others)
    }
}
