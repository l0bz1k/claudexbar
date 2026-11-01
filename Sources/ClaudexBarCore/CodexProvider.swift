import Foundation

public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex
    public let displayName = ProviderID.codex.displayName

    private let authReader: any CodexAuthReading
    private let httpClient: any HTTPClient
    private let usageURL: URL
    private let resetCreditsURL: URL
    private let resetCache = ResetDetailCache()

    public init(
        authReader: any CodexAuthReading = CodexAuthReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        resetCreditsURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    ) {
        self.authReader = authReader
        self.httpClient = httpClient
        self.usageURL = usageURL
        self.resetCreditsURL = resetCreditsURL
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        do {
            let token = try authReader.readAccessToken()
            var request = URLRequest(url: usageURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let accountID = authReader.readAccountID() {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = 15

            let response = try await httpClient.data(for: request)
            switch response.statusCode {
            case 200..<300:
                let snapshot = try Self.parseUsageResponse(response.data, fetchedAt: Date())
                return .success(snapshot.withResets(await bankedResets(usage: response.data, template: request)))
            case 401:
                return .failure(.authExpired)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(EdgeBlockDetector.blockError(statusCode: response.statusCode, body: response.data) ?? .server(statusCode: response.statusCode))
            }
        } catch let error as UsageError {
            return .failure(error)
        } catch is DecodingError {
            return .failure(.decoding)
        } catch {
            return .failure(.network)
        }
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("codex", ["login"])
    }

    /// The count rides along with every usage response; the details (title,
    /// expiry) need a separate GET, made only when there are resets and at
    /// most every 6 hours unless the count changes. A failed detail call keeps
    /// the last details — or shows just the count.
    private func bankedResets(usage: Data, template: URLRequest) async -> BankedResets? {
        guard let count = BankedResetParser.codexCount(usage) else { return nil }
        guard count > 0 else {
            resetCache.store(count: 0, items: [])
            return nil
        }
        if let cached = resetCache.fresh(count: count) {
            return BankedResets(count: count, items: cached)
        }
        var request = template
        request.url = resetCreditsURL
        if let response = try? await httpClient.data(for: request),
           (200..<300).contains(response.statusCode),
           let items = BankedResetParser.codexDetails(response.data) {
            resetCache.store(count: count, items: items)
            return BankedResets(count: count, items: items)
        }
        return BankedResets(count: count, items: resetCache.stale() ?? [])
    }

    public static func parseUsageResponse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let primary = response.rateLimit.primaryWindow
        let secondary = response.rateLimit.secondaryWindow
        let windows = [primary, secondary].compactMap { $0 }

        var fiveHour: CodexUsageResponse.Window?
        var weekly: CodexUsageResponse.Window?
        var fiveHourLabel = "5h"
        var weeklyLabel = "1w"
        for window in windows {
            switch window.limitWindowSeconds {
            case 18_000:
                fiveHour = window
            case 604_800:
                weekly = window
            case nil:
                // No duration metadata at all: handled by the legacy
                // primary/secondary fallback below. Don't let it fall
                // through to the "unrecognized duration" branch.
                break
            default:
                // Some plans (e.g. ChatGPT Go) report a single window with a
                // non-standard duration such as a 30-day/monthly cap instead
                // of the usual 5h/7d pair. Rather than failing to parse,
                // surface it in the weekly slot with an honest label derived
                // from the actual duration.
                if weekly == nil {
                    weekly = window
                    weeklyLabel = Self.windowLabel(forSeconds: window.limitWindowSeconds)
                } else if fiveHour == nil {
                    fiveHour = window
                    fiveHourLabel = Self.windowLabel(forSeconds: window.limitWindowSeconds)
                }
            }
        }

        // Older valid responses omitted duration metadata and used stable
        // primary/secondary positions. Keep that shape backwards compatible.
        if windows.allSatisfy({ $0.limitWindowSeconds == nil }),
           let primary,
           let secondary {
            fiveHour = primary
            weekly = secondary
        }

        guard fiveHour != nil || weekly != nil else {
            throw UsageError.decoding
        }

        func usageWindow(_ window: CodexUsageResponse.Window?, label: String, fallbackDuration: TimeInterval) -> UsageWindow? {
            window.map {
                UsageWindow(
                    windowLabel: label,
                    remainingPercent: clampPercent(100 - $0.usedPercent),
                    resetAt: fetchedAt.addingTimeInterval(TimeInterval($0.resetAfterSeconds)),
                    windowDuration: $0.limitWindowSeconds.map(TimeInterval.init) ?? fallbackDuration
                )
            }
        }

        return UsageSnapshot(
            primary: usageWindow(fiveHour, label: fiveHourLabel, fallbackDuration: 5 * 60 * 60),
            secondary: usageWindow(weekly, label: weeklyLabel, fallbackDuration: 7 * 24 * 60 * 60),
            fetchedAt: fetchedAt
        )
    }

    private static func windowLabel(forSeconds seconds: Int?) -> String {
        guard let seconds else { return "1w" }
        if seconds % 86_400 == 0 {
            return "\(seconds / 86_400)d"
        }
        if seconds % 3_600 == 0 {
            return "\(seconds / 3_600)h"
        }
        return "1w"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Int
        let resetAfterSeconds: Int
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = clampPercent(try container.decodeLossyDouble(forKey: .usedPercent))
            resetAfterSeconds = try container.decode(Int.self, forKey: .resetAfterSeconds)
            limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decode(String.self, forKey: key), let double = Double(value) {
            return double
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected numeric value")
    }
}

/// Last fetched reset details, reused while the count is unchanged.
final class ResetDetailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var count = -1
    private var items: [BankedReset] = []
    private var fetchedAt = Date.distantPast
    private let maxAge: TimeInterval = 6 * 60 * 60

    func fresh(count: Int, now: Date = Date()) -> [BankedReset]? {
        lock.withLock { self.count == count && now.timeIntervalSince(fetchedAt) < maxAge ? items : nil }
    }

    func stale() -> [BankedReset]? {
        lock.withLock { count >= 0 ? items : nil }
    }

    func store(count: Int, items: [BankedReset], now: Date = Date()) {
        lock.withLock {
            self.count = count
            self.items = items
            self.fetchedAt = now
        }
    }
}
