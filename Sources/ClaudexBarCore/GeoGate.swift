import Foundation
import Security
#if canImport(Network)
import Network
#endif

// MARK: - Paranoid Mode
//
// Before any request to Claude or Codex leaves the app, the exit IP's country
// is looked up and compared with the countries the user allows. Nothing is
// sent unless every GeoIP source agrees on an allowed country: a source that
// fails, times out or answers nonsense blocks the request (fail-closed).
//
// The GeoIP lookups go out from the ClaudexBar process itself, so per-process
// routing rules (VPN/proxy by process name) send them the same way as the
// provider requests they guard.

/// What Paranoid Mode allows. `nil` from the configuration closure means the
/// mode is off.
public struct ParanoidConfiguration: Equatable, Sendable {
    public var allowedCountries: Set<String>

    public init(allowedCountries: Set<String>) {
        self.allowedCountries = Set(allowedCountries.compactMap(CountryCode.normalize))
    }
}

public enum CountryCode {
    /// An ISO 3166-1 alpha-2 code ("nl" → "NL"), or nil for anything else:
    /// empty, junk, Cloudflare's "XX" (unknown) and "T1" (Tor).
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }), code != "XX" else {
            return nil
        }
        return code
    }

    /// Codes macOS knows as regions, for validating user input.
    public static func isKnownRegion(_ code: String) -> Bool {
        guard let code = normalize(code) else { return false }
        return Locale.Region.isoRegions.contains { $0.identifier == code }
    }

    public static func displayName(_ code: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }
}

/// One GeoIP service's answer.
public struct GeoObservation: Equatable, Sendable {
    public let source: String
    /// ISO code, or nil when the lookup failed.
    public let country: String?
    /// Why the lookup failed (no secrets: a status code or error kind).
    public let failure: String?
    /// The service refused because a request quota ran out (HTTP 429).
    public let quotaExhausted: Bool

    public init(source: String, country: String?, failure: String? = nil, quotaExhausted: Bool = false) {
        self.source = source
        self.country = country
        self.failure = failure
        self.quotaExhausted = quotaExhausted
    }
}

/// The result of one round of lookups, judged against the allowed countries.
public struct GeoCheck: Equatable, Sendable {
    public let observations: [GeoObservation]
    public let allowedCountries: Set<String>
    public let checkedAt: Date

    public init(observations: [GeoObservation], allowedCountries: Set<String>, checkedAt: Date) {
        self.observations = observations
        self.allowedCountries = allowedCountries
        self.checkedAt = checkedAt
    }

    /// Every source answered, and every answer is an allowed country.
    public var permitsRequests: Bool {
        !observations.isEmpty && observations.allSatisfy { observation in
            observation.country.map(allowedCountries.contains) ?? false
        }
    }

    /// Sources whose request quota ran out.
    public var quotaExhaustedSources: [String] {
        observations.filter(\.quotaExhausted).map(\.source)
    }

    /// Distinct countries seen, in source order.
    public var observedCountries: [String] {
        var seen: [String] = []
        for code in observations.compactMap(\.country) where !seen.contains(code) { seen.append(code) }
        return seen
    }

    /// "exit IP in NL", "exit IP in DE", "GeoIP sources disagree (NL / DE)",
    /// "GeoIP lookup failed (ipinfo.io: HTTP 429)", "no allowed countries selected".
    public var summary: String {
        if allowedCountries.isEmpty { return "no allowed countries selected" }
        let failed = observations.filter { $0.country == nil }
        if !failed.isEmpty {
            let detail = failed.map { "\($0.source): \($0.failure ?? "no answer")" }.joined(separator: ", ")
            return "GeoIP lookup failed (\(detail))"
        }
        let countries = observedCountries
        if countries.count > 1, !permitsRequests {
            return "GeoIP sources disagree (\(countries.joined(separator: " / ")))"
        }
        return "exit IP in \(countries.joined(separator: " / "))"
    }
}

public enum GeoVerdict: Equatable, Sendable {
    /// Paranoid Mode is off: requests go out unchecked.
    case disabled
    case checked(GeoCheck)

    public var permitsRequests: Bool {
        switch self {
        case .disabled: return true
        case .checked(let check): return check.permitsRequests
        }
    }

    public var check: GeoCheck? {
        if case .checked(let check) = self { return check }
        return nil
    }
}

// MARK: - Sources

public protocol GeoIPSource: Sendable {
    var name: String { get }
    func makeRequest(timeout: TimeInterval) -> URLRequest
    /// The ISO country code in a successful response body, or nil.
    func parseCountry(_ body: Data) -> String?
    /// What a non-2xx answer means, in words for the menu and the log.
    func describeFailure(statusCode: Int, authenticated: Bool) -> (detail: String, quotaExhausted: Bool)
}

extension GeoIPSource {
    public func describeFailure(statusCode: Int, authenticated: Bool) -> (detail: String, quotaExhausted: Bool) {
        statusCode == 429 ? ("rate limited (HTTP 429)", true) : ("HTTP \(statusCode)", false)
    }
}

/// `https://1.1.1.1/cdn-cgi/trace`: plain `key=value` lines, `loc=NL`.
public struct CloudflareTraceGeoSource: GeoIPSource {
    public let name = "1.1.1.1"
    public static let url = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    public init() {}

    public func makeRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = timeout
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        return request
    }

    public func parseCountry(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("loc=") {
            return CountryCode.normalize(String(line.dropFirst(4)))
        }
        return nil
    }
}

/// ipinfo.io. With a (free) IPinfo Lite token: `api.ipinfo.io/lite/me`,
/// no request cap. Without one: the public `ipinfo.io/country`, limited to
/// 1,000 requests a day per IP — shared by everyone behind the same VPN exit.
/// The token goes in the Authorization header, never in the URL.
public struct IPInfoGeoSource: GeoIPSource {
    public let name = "ipinfo.io"
    public static let publicURL = URL(string: "https://ipinfo.io/country")!
    public static let liteURL = URL(string: "https://api.ipinfo.io/lite/me")!

    private let token: @Sendable () -> String?

    public init(token: @escaping @Sendable () -> String? = { nil }) {
        self.token = token
    }

    public func makeRequest(timeout: TimeInterval) -> URLRequest {
        let token = self.token()?.trimmingCharacters(in: .whitespacesAndNewlines)
        var request: URLRequest
        if let token, !token.isEmpty {
            request = URLRequest(url: Self.liteURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            request = URLRequest(url: Self.publicURL)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = timeout
        return request
    }

    /// Lite answers JSON (`country_code`), the public endpoint a bare code.
    public func parseCountry(_ body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            return CountryCode.normalize(object["country_code"] as? String)
        }
        return CountryCode.normalize(String(data: body, encoding: .utf8))
    }

    public func describeFailure(statusCode: Int, authenticated: Bool) -> (detail: String, quotaExhausted: Bool) {
        switch (statusCode, authenticated) {
        case (429, false):
            return ("daily limit reached — 1,000/day without a token, shared by everyone on this IP", true)
        case (429, true):
            return ("rate limited (HTTP 429)", true)
        case (401, true), (403, true):
            return ("token rejected (HTTP \(statusCode))", false)
        default:
            return ("HTTP \(statusCode)", false)
        }
    }
}

// MARK: - Gate

public actor GeoGate {
    public static func defaultSources(ipinfoToken: @escaping @Sendable () -> String? = { nil }) -> [any GeoIPSource] {
        [CloudflareTraceGeoSource(), IPInfoGeoSource(token: ipinfoToken)]
    }

    private let configuration: @Sendable () -> ParanoidConfiguration?
    private let sources: [any GeoIPSource]
    private let httpClient: any HTTPClient
    private let cacheTTL: TimeInterval
    private let blockedRecheckInterval: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: (observations: [GeoObservation], at: Date, generation: Int)?
    private var inFlight: (task: Task<[GeoObservation], Never>, generation: Int)?
    /// Bumped on every network change: lookups from before it don't count.
    private var generation = 0
    private var latest: GeoCheck?
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif

    /// - Parameters:
    ///   - cacheTTL: how long one round of lookups covers further requests.
    ///     Short on purpose: it only folds the few calls of one poll (usage,
    ///     profile, token refresh; Claude and Codex polled together) into one
    ///     check, and a network change discards it at once.
    ///   - blockedRecheckInterval: while requests are held back, how long a
    ///     blocking answer stands before the services are asked again. Polls
    ///     in between stay blocked without spending GeoIP quota; a network
    ///     change, a settings change or "Check Exit IP Now" asks at once.
    public init(
        configuration: @escaping @Sendable () -> ParanoidConfiguration?,
        sources: [any GeoIPSource] = GeoGate.defaultSources(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        cacheTTL: TimeInterval = 20,
        blockedRecheckInterval: TimeInterval = 5 * 60,
        timeout: TimeInterval = 6,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.sources = sources
        self.httpClient = httpClient
        self.cacheTTL = cacheTTL
        self.blockedRecheckInterval = blockedRecheckInterval
        self.timeout = timeout
        self.now = now
    }

    /// The most recent check, for the menu's status line.
    public var lastCheck: GeoCheck? { latest }

    /// Decides whether a Claude/Codex request may go out right now.
    public func verify() async -> GeoVerdict {
        guard let config = configuration() else { return .disabled }
        guard !config.allowedCountries.isEmpty else {
            // Nothing allowed means nothing goes out; no lookup needed.
            let check = GeoCheck(observations: [], allowedCountries: [], checkedAt: now())
            latest = check
            return .checked(check)
        }
        // A network change during a lookup makes its answer suspect: look
        // again, but not forever — a network that keeps flapping blocks.
        for _ in 0..<3 {
            let generationAtStart = generation
            let observations = await currentObservations(allowed: config.allowedCountries)
            if generationAtStart == generation {
                let check = GeoCheck(observations: observations, allowedCountries: config.allowedCountries, checkedAt: cached?.at ?? now())
                latest = check
                return .checked(check)
            }
        }
        let check = GeoCheck(
            observations: sources.map { GeoObservation(source: $0.name, country: nil, failure: "network kept changing") },
            allowedCountries: config.allowedCountries,
            checkedAt: now()
        )
        latest = check
        return .checked(check)
    }

    /// A fresh lookup on demand ("Check Exit IP Now"), whether or not the
    /// mode is on, judged against `allowedCountries`. With the mode on, it
    /// also becomes the answer the next requests use.
    public func probe(allowedCountries: Set<String>) async -> GeoCheck {
        invalidate()
        let allowed = ParanoidConfiguration(allowedCountries: allowedCountries).allowedCountries
        let observations = await currentObservations(allowed: allowed)
        let check = GeoCheck(observations: observations, allowedCountries: allowed, checkedAt: now())
        if configuration() != nil { latest = check }
        return check
    }

    /// Forget the cached answer (network changed, user asked to re-check).
    public func invalidate() {
        generation += 1
        cached = nil
        inFlight = nil
    }

    /// Watch for interface changes (VPN up/down, Wi-Fi switch) and drop the
    /// cached answer the moment one happens.
    public func startMonitoringNetworkChanges() {
        #if canImport(Network)
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.invalidate() }
        }
        monitor.start(queue: DispatchQueue(label: "ClaudexBar.GeoGate.path"))
        pathMonitor = monitor
        #endif
    }

    private func currentObservations(allowed: Set<String>) async -> [GeoObservation] {
        if let cached, cached.generation == generation {
            let permits = GeoCheck(observations: cached.observations, allowedCountries: allowed, checkedAt: cached.at).permitsRequests
            if now().timeIntervalSince(cached.at) < (permits ? cacheTTL : blockedRecheckInterval) {
                return cached.observations
            }
        }
        if let inFlight, inFlight.generation == generation {
            return await inFlight.task.value
        }
        let lookupGeneration = generation
        let sources = self.sources
        let client = self.httpClient
        let timeout = self.timeout
        let task = Task { await Self.lookUp(sources: sources, httpClient: client, timeout: timeout) }
        inFlight = (task, lookupGeneration)
        let observations = await task.value
        if inFlight?.generation == lookupGeneration { inFlight = nil }
        if lookupGeneration == generation {
            cached = (observations, now(), lookupGeneration)
        }
        return observations
    }

    /// Asks every source at once.
    static func lookUp(sources: [any GeoIPSource], httpClient: any HTTPClient, timeout: TimeInterval) async -> [GeoObservation] {
        await withTaskGroup(of: (Int, GeoObservation).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await lookUp(source: source, httpClient: httpClient, timeout: timeout))
                }
            }
            var results: [(Int, GeoObservation)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func lookUp(source: any GeoIPSource, httpClient: any HTTPClient, timeout: TimeInterval) async -> GeoObservation {
        let request = source.makeRequest(timeout: timeout)
        let authenticated = request.value(forHTTPHeaderField: "Authorization") != nil
        do {
            let response = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                let failure = source.describeFailure(statusCode: response.statusCode, authenticated: authenticated)
                return GeoObservation(source: source.name, country: nil, failure: failure.detail, quotaExhausted: failure.quotaExhausted)
            }
            guard let country = source.parseCountry(response.data) else {
                return GeoObservation(source: source.name, country: nil, failure: "unreadable answer")
            }
            return GeoObservation(source: source.name, country: country)
        } catch let error as URLError where error.code == .timedOut {
            return GeoObservation(source: source.name, country: nil, failure: "timed out")
        } catch {
            return GeoObservation(source: source.name, country: nil, failure: "unreachable")
        }
    }
}

// MARK: - Gated client

/// Wraps the HTTP client of a provider whose traffic Paranoid Mode guards:
/// the request is sent only when the gate allows it, otherwise it fails with
/// `UsageError.geoBlocked` and nothing leaves the Mac.
public struct GeoGatedHTTPClient: HTTPClient {
    private let base: any HTTPClient
    private let gate: GeoGate

    public init(base: any HTTPClient = URLSessionHTTPClient(), gate: GeoGate) {
        self.base = base
        self.gate = gate
    }

    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let verdict = await gate.verify()
        if case .checked(let check) = verdict, !check.permitsRequests {
            throw UsageError.geoBlocked(check.summary)
        }
        return try await base.data(for: request)
    }
}

// MARK: - IPinfo token

/// The IPinfo Lite token, in the login Keychain (written by ClaudexBar, so
/// reading it never prompts). Never logged, never put in a URL.
public struct IPInfoTokenStore: Sendable {
    public static let service = "ClaudexBar-IPinfo-Token"
    private let account = "default"

    public init() {}

    public func save(_ token: String) throws {
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UsageError.keychain }
            return
        }
        throw UsageError.keychain
    }

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        KeychainDiagnostics.noteReadStatus(status, service: Self.service)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    public func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ] as CFDictionary)
    }
}
