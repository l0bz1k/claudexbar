import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id: ProviderID = .claude
    public let displayName = ProviderID.claude.displayName

    private let credentialReader: any ClaudeCredentialReading
    private let httpClient: any HTTPClient
    private let usageURL: URL
    private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private let planCache = PlanCache()
    private let refreshURL: URL
    private let now: @Sendable () -> Date
    private let persistRefreshed: (@Sendable (ClaudeCredentials) -> Void)?
    private let diagnostics: (@Sendable (String) -> Void)?
    private let resetsStatus = ResetsStatusMemo()
    private let retryAfter = RetryAfterMemo()

    public func rateLimitRetryAfter() -> TimeInterval? { retryAfter.current }

    public init(
        credentialReader: any ClaudeCredentialReading = ClaudeCredentialReader(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        // `cedar_ember=1` adds the banked limit resets; the rest is unchanged.
        usageURL: URL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!,
        refreshURL: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        now: @escaping @Sendable () -> Date = { Date() },
        persistRefreshed: (@Sendable (ClaudeCredentials) -> Void)? = nil,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.diagnostics = diagnostics
        self.credentialReader = credentialReader
        self.httpClient = httpClient
        self.usageURL = usageURL
        self.refreshURL = refreshURL
        self.now = now
        self.persistRefreshed = persistRefreshed
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        // Try each credential in order, reading a source only when the ones
        // before it didn't work out. Only an *auth* failure moves on to the
        // next one; network, rate-limit and server errors are about the
        // service, and another credential wouldn't fare better.
        var lastError = UsageError.missingAuth
        for loader in credentialReader.credentialLoaders() {
            guard let credentials = loader.load() else { continue }
            let candidate = ClaudeCredentialCandidate(credentials: credentials, source: loader.source)
            let result = await fetchUsage(with: candidate)
            guard case .failure(let error) = result else { return result }
            lastError = error
            switch error {
            case .missingAuth, .authExpired, .refreshFailed:
                continue
            default:
                return result
            }
        }
        return .failure(lastError)
    }

    private func fetchUsage(with candidate: ClaudeCredentialCandidate) async -> Result<UsageSnapshot, UsageError> {
        let credentials = candidate.credentials
        let mayRefresh = candidate.source.mayRefresh
        do {
            if Self.isExpired(credentials.expiresAt, now: now()) {
                // Someone else's expired credential is left alone: Claude Code
                // refreshes its own token the next time it runs.
                guard mayRefresh, let refreshToken = credentials.refreshToken else {
                    return .failure(.authExpired)
                }
                let refreshed = try await refreshAccessToken(refreshToken)
                // Claude rotates the refresh token on every refresh: the old one
                // is spent, the new one is already saved. If the brand-new access
                // token still gets a 401, don't refresh again in this poll — a
                // second refresh with the spent token would fail and discard the
                // freshly saved session.
                return try await fetchUsage(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken, allowRefresh: false)
            }
            return try await fetchUsage(accessToken: credentials.accessToken, refreshToken: mayRefresh ? credentials.refreshToken : nil)
        } catch let error as UsageError {
            return .failure(error)
        } catch is DecodingError {
            return .failure(.decoding)
        } catch {
            return .failure(.network)
        }
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("claude", ["setup-token"])
    }

    public static func parseUsageResponse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        guard let fiveHour = response.fiveHour else {
            throw UsageError.decoding
        }
        let sevenDay = response.sevenDay ?? response.sevenDaySonnet ?? response.sevenDayOpus

        return UsageSnapshot(
            primary: UsageWindow(
                windowLabel: "5h",
                remainingPercent: clampPercent(100 - fiveHour.utilization),
                resetAt: ISO8601DateFormatter.parseClaudexDate(fiveHour.resetsAt),
                windowDuration: 5 * 60 * 60
            ),
            // No weekly field at all (a plan or response shape without one)
            // means no weekly window — not a made-up 0%.
            secondary: sevenDay.map { week in
                UsageWindow(
                    windowLabel: "7d",
                    remainingPercent: clampPercent(100 - week.utilization),
                    resetAt: ISO8601DateFormatter.parseClaudexDate(week.resetsAt),
                    windowDuration: 7 * 24 * 60 * 60
                )
            },
            fetchedAt: fetchedAt
        )
    }

    /// The subscription ("Pro", "Max 5x") from `/api/oauth/profile`, asked
    /// with the same credential that just worked — never by reading another
    /// app's Keychain item. Fetched at most every 6 hours; a failure keeps the
    /// last known label.
    private func planLabel(accessToken: String) async -> String? {
        let key = PlanCache.tag(stripBearerPrefix(accessToken))
        if let cached = planCache.fresh(key: key) { return cached }
        var request = URLRequest(url: profileURL)
        request.setValue(ClaudeCodeIdentity.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(stripBearerPrefix(accessToken))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        if let response = try? await httpClient.data(for: request), (200..<300).contains(response.statusCode) {
            planCache.store(PlanLabels.claude(fromProfile: response.data), key: key)
        } else {
            planCache.store(nil, key: key) // try again after the cache period, keep the last label meanwhile
        }
        return planCache.last(key: key)
    }

    static func isExpired(_ expiresAt: Int?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        let nowMs = Int(now.timeIntervalSince1970 * 1_000)
        return expiresAt < nowMs + 60_000
    }

    private func fetchUsage(accessToken: String, refreshToken: String?, allowRefresh: Bool = true) async throws -> Result<UsageSnapshot, UsageError> {
        var request = URLRequest(url: usageURL)
        request.setValue(ClaudeCodeIdentity.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(stripBearerPrefix(accessToken))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let response = try await httpClient.data(for: request)
        switch response.statusCode {
        case 200..<300:
            if let diagnostics, let line = resetsStatus.changed(BankedResetParser.claudeResetsStatus(response.data)) {
                diagnostics(line)
            }
            let snapshot = try Self.parseUsageResponse(response.data, fetchedAt: now())
                .withResets(BankedResetParser.claude(response.data))
                .withCredit(BankedResetParser.claudeIncludedCredit(response.data))
            return .success(snapshot.withPlan(await planLabel(accessToken: accessToken)))
        case 401:
            // Just refreshed: a second refresh in the same poll won't help.
            guard allowRefresh, let refreshToken else { return .failure(.authExpired) }
            do {
                let refreshed = try await refreshAccessToken(refreshToken)
                return try await fetchUsage(accessToken: refreshed.accessToken, refreshToken: nil)
            } catch {
                return .failure(.authExpired)
            }
        case 429:
            retryAfter.set(response.retryAfter)
            return .failure(.rateLimited)
        default:
            return .failure(EdgeBlockDetector.blockError(statusCode: response.statusCode, body: response.data) ?? .server(statusCode: response.statusCode))
        }
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> ClaudeCredentials {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeOAuthFlow.clientID
        ])
        request.timeoutInterval = 15

        let response = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            // 400 (invalid_grant) / 401: the server rejected this refresh
            // token for good. Drop the dead own session so it stops shadowing
            // Claude Code's login; transient 5xx/429 leave it in place.
            if response.statusCode == 400 || response.statusCode == 401 {
                credentialReader.discardOwnedCredentials()
            }
            throw UsageError.refreshFailed
        }
        guard let refreshed = Self.parseRefreshResponse(response.data, fallbackRefreshToken: refreshToken, now: now()) else {
            throw UsageError.refreshFailed
        }
        // Persist the rotated credential so the next refresh uses the new
        // refresh token (Claude rotates it on every refresh).
        persistRefreshed?(refreshed)
        return refreshed
    }

    public static func parseRefreshResponse(_ data: Data, fallbackRefreshToken: String, now: Date) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (root["access_token"] as? String).map(stripBearerPrefix),
              !accessToken.isEmpty else {
            return nil
        }
        let rotated = (root["refresh_token"] as? String).flatMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var expiresAt: Int?
        if let expiresIn = root["expires_in"] as? Int {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + expiresIn * 1_000
        } else if let expiresIn = root["expires_in"] as? Double {
            expiresAt = Int(now.timeIntervalSince1970 * 1_000) + Int(expiresIn * 1_000)
        }
        return ClaudeCredentials(accessToken: accessToken, refreshToken: rotated ?? fallbackRefreshToken, expiresAt: expiresAt)
    }

    /// Same `application/x-www-form-urlencoded` encoder as the sign-in flow.
    /// (The previous local encoder used `.urlQueryAllowed`, which leaves `+`,
    /// `&` and `=` unescaped — harmless for today's token alphabet, but a `+`
    /// in a form body decodes as a space and `&`/`=` would split the field.)
    private func formBody(_ values: [String: String]) -> Data {
        ClaudeOAuthFlow.formBody(values)
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

/// Remembers the last banked-resets status so it's logged only on change.
final class ResetsStatusMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?

    func changed(_ status: String?) -> String? {
        guard let status else { return nil }
        return lock.withLock {
            guard status != last else { return nil }
            last = status
            return status
        }
    }
}
