import Foundation
import Security
#if canImport(Network)
import Network
#endif

// MARK: - Paranoid Mode
//
// Before any request to Claude or Codex leaves the app, the exit IP's country
// is looked up and compared with the countries the user allows. Nothing is
// sent unless a majority of the GeoIP sources (two of three) confirm an
// allowed country — or see an exit IP the user trusts. A source that fails,
// times out or answers nonsense counts against (fail-closed): with one
// source down, the other two must both agree.
//
// The GeoIP lookups go out from the ClaudexBar process itself, so per-process
// routing rules (VPN/proxy by process name) send them the same way as the
// provider requests they guard.

/// What Paranoid Mode allows. `nil` from the configuration closure means the
/// mode is off.
public struct ParanoidConfiguration: Equatable, Sendable {
    public var allowedCountries: Set<String>
    /// Exit IPs the user vouches for: when most sources see one of these,
    /// requests go out whatever country the GeoIP databases put it in.
    public var trustedIPs: Set<String>

    public init(allowedCountries: Set<String>, trustedIPs: Set<String> = []) {
        self.allowedCountries = Set(allowedCountries.compactMap(CountryCode.normalize))
        self.trustedIPs = Set(trustedIPs.compactMap(IPAddressText.normalize))
    }

    /// Nothing at all is allowed: no lookup needed, nothing goes out.
    public var allowsNothing: Bool { allowedCountries.isEmpty && trustedIPs.isEmpty }
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

public enum IPAddressText {
    /// A canonical textual IPv4/IPv6 address ("2001:DB8:0::1" → "2001:db8::1"),
    /// or nil for anything that isn't one.
    public static func normalize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &v4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil ? String(cString: buffer) : nil
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil ? String(cString: buffer) : nil
        }
        return nil
    }
}

/// One GeoIP service's answer.
public struct GeoObservation: Equatable, Sendable {
    public let source: String
    /// ISO code, or nil when the lookup failed.
    public let country: String?
    /// The exit IP the service saw, when it says.
    public let ip: String?
    /// Why the lookup failed (no secrets: a status code or error kind).
    public let failure: String?
    /// The service refused because a request quota ran out (HTTP 429).
    public let quotaExhausted: Bool

    public init(source: String, country: String?, ip: String? = nil, failure: String? = nil, quotaExhausted: Bool = false) {
        self.source = source
        self.country = country
        self.ip = IPAddressText.normalize(ip)
        self.failure = failure
        self.quotaExhausted = quotaExhausted
    }
}

/// The result of one round of lookups, judged by majority: requests go out
/// when more than half of *all* sources (a failed one counts against)
/// confirm an allowed country — or see a trusted exit IP. With three
/// sources that's two; with two, both.
public struct GeoCheck: Equatable, Sendable {
    public let observations: [GeoObservation]
    public let allowedCountries: Set<String>
    public let trustedIPs: Set<String>
    public let checkedAt: Date

    public init(observations: [GeoObservation], allowedCountries: Set<String>, trustedIPs: Set<String> = [], checkedAt: Date) {
        self.observations = observations
        self.allowedCountries = allowedCountries
        self.trustedIPs = Set(trustedIPs.compactMap(IPAddressText.normalize))
        self.checkedAt = checkedAt
    }

    /// Votes needed: more than half of the sources asked.
    public var majority: Int { observations.count / 2 + 1 }

    /// Sources that put the exit IP in an allowed country.
    public var allowedVotes: Int {
        observations.filter { $0.country.map(allowedCountries.contains) ?? false }.count
    }

    /// The trusted exit IP most sources see, if any.
    public var trustedExitIP: String? {
        guard !observations.isEmpty, !trustedIPs.isEmpty else { return nil }
        let seen = observations.compactMap(\.ip).filter(trustedIPs.contains)
        for ip in Set(seen) where seen.filter({ $0 == ip }).count >= majority { return ip }
        return nil
    }

    public var permitsRequests: Bool {
        guard !observations.isEmpty else { return false }
        if trustedExitIP != nil { return true }
        return allowedVotes >= majority
    }

    /// Requests go out only because the exit IP is trusted.
    public var permittedByTrustedIP: Bool {
        trustedExitIP != nil && allowedVotes < majority
    }

    /// The exit IP most sources agree on (for "Trust this IP").
    public var consensusIP: String? {
        let seen = observations.compactMap(\.ip)
        for ip in Set(seen) where seen.filter({ $0 == ip }).count >= majority { return ip }
        return nil
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

    /// "exit IP in NL", "exit IP in NL (2 of 3 sources; 1.1.1.1 says DE)",
    /// "exit IP 203.0.113.7 is trusted (sources say DE / NL)",
    /// "GeoIP sources disagree (NL / DE)", "GeoIP lookup failed (ipinfo.io:
    /// HTTP 429)", "no allowed countries selected".
    public var summary: String {
        if allowedCountries.isEmpty && trustedIPs.isEmpty { return "no allowed countries selected" }
        let countries = observedCountries
        let failed = observations.filter { $0.country == nil }

        if permitsRequests {
            if permittedByTrustedIP, let ip = trustedExitIP {
                let said = countries.isEmpty ? "" : " (sources say \(countries.joined(separator: " / ")))"
                return "exit IP \(ip) is trusted\(said)"
            }
            let allowedSeen = countries.filter(allowedCountries.contains)
            var text = "exit IP in \(allowedSeen.joined(separator: " / "))"
            if allowedVotes < observations.count {
                let dissent = observations.filter { !($0.country.map(allowedCountries.contains) ?? false) }
                    .map { "\($0.source) says \($0.country ?? ($0.failure ?? "nothing"))" }
                text += " (\(allowedVotes) of \(observations.count) sources; \(dissent.joined(separator: ", ")))"
            }
            return text
        }

        var parts: [String] = []
        if !failed.isEmpty {
            let detail = failed.map { "\($0.source): \($0.failure ?? "no answer")" }.joined(separator: ", ")
            parts.append("GeoIP lookup failed (\(detail))")
        }
        if countries.count > 1 {
            parts.append("GeoIP sources disagree (\(countries.joined(separator: " / ")))")
        } else if failed.isEmpty, !countries.isEmpty {
            parts.append("exit IP in \(countries[0])")
        }
        if observations.count > 2, failed.count < observations.count {
            parts.append("\(allowedVotes) of \(observations.count) confirm an allowed country, \(majority) needed")
        }
        return parts.isEmpty ? "country not confirmed" : parts.joined(separator: "; ")
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
    /// The exit IP in a successful response body, when the service reports it.
    func parseIP(_ body: Data) -> String?
    /// What a non-2xx answer means, in words for the menu and the log.
    func describeFailure(statusCode: Int, authenticated: Bool) -> (detail: String, quotaExhausted: Bool)
}

extension GeoIPSource {
    public func parseIP(_ body: Data) -> String? { nil }

    /// A JSON object body, or nil.
    func jsonObject(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

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

    public func parseIP(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            return IPAddressText.normalize(String(line.dropFirst(3)))
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
    /// `/json` rather than `/country`: same quota, but it also names the IP.
    public static let publicURL = URL(string: "https://ipinfo.io/json")!
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
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.timeoutInterval = timeout
        return request
    }

    /// Lite answers `country_code`, the public `/json` endpoint `country`;
    /// a bare code (the old `/country` endpoint) is read too.
    public func parseCountry(_ body: Data) -> String? {
        if let object = jsonObject(body) {
            return CountryCode.normalize((object["country_code"] as? String) ?? (object["country"] as? String))
        }
        return CountryCode.normalize(String(data: body, encoding: .utf8))
    }

    public func parseIP(_ body: Data) -> String? {
        IPAddressText.normalize(jsonObject(body)?["ip"] as? String)
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

/// `https://get.geojs.io/v1/ip/geo.json`: no key, no published rate limit,
/// its own data (it doesn't simply echo Cloudflare's or IPinfo's answer).
public struct GeoJSGeoSource: GeoIPSource {
    public let name = "geojs.io"
    public static let url = URL(string: "https://get.geojs.io/v1/ip/geo.json")!

    public init() {}

    public func makeRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func parseCountry(_ body: Data) -> String? {
        CountryCode.normalize(jsonObject(body)?["country_code"] as? String)
    }

    public func parseIP(_ body: Data) -> String? {
        IPAddressText.normalize(jsonObject(body)?["ip"] as? String)
    }
}

// MARK: - Gate

public actor GeoGate {
    public static func defaultSources(ipinfoToken: @escaping @Sendable () -> String? = { nil }) -> [any GeoIPSource] {
        [CloudflareTraceGeoSource(), IPInfoGeoSource(token: ipinfoToken), GeoJSGeoSource()]
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
        guard !config.allowsNothing else {
            // Nothing allowed means nothing goes out; no lookup needed.
            let check = GeoCheck(observations: [], allowedCountries: [], checkedAt: now())
            latest = check
            return .checked(check)
        }
        // A network change during a lookup makes its answer suspect: look
        // again, but not forever — a network that keeps flapping blocks.
        for _ in 0..<3 {
            let generationAtStart = generation
            let observations = await currentObservations(config: config)
            if generationAtStart == generation {
                let check = GeoCheck(observations: observations, allowedCountries: config.allowedCountries, trustedIPs: config.trustedIPs, checkedAt: cached?.at ?? now())
                latest = check
                return .checked(check)
            }
        }
        let check = GeoCheck(
            observations: sources.map { GeoObservation(source: $0.name, country: nil, failure: "network kept changing") },
            allowedCountries: config.allowedCountries,
            trustedIPs: config.trustedIPs,
            checkedAt: now()
        )
        latest = check
        return .checked(check)
    }

    /// A fresh lookup on demand ("Check Exit IP Now"), whether or not the
    /// mode is on, judged against `allowedCountries`. With the mode on, it
    /// also becomes the answer the next requests use.
    public func probe(allowedCountries: Set<String>, trustedIPs: Set<String> = []) async -> GeoCheck {
        invalidate()
        let config = ParanoidConfiguration(allowedCountries: allowedCountries, trustedIPs: trustedIPs)
        let observations = await currentObservations(config: config)
        let check = GeoCheck(observations: observations, allowedCountries: config.allowedCountries, trustedIPs: config.trustedIPs, checkedAt: now())
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

    private func currentObservations(config: ParanoidConfiguration) async -> [GeoObservation] {
        if let cached, cached.generation == generation {
            let permits = GeoCheck(observations: cached.observations, allowedCountries: config.allowedCountries, trustedIPs: config.trustedIPs, checkedAt: cached.at).permitsRequests
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
            let ip = source.parseIP(response.data)
            guard let country = source.parseCountry(response.data) else {
                return GeoObservation(source: source.name, country: nil, ip: ip, failure: "unreadable answer")
            }
            return GeoObservation(source: source.name, country: country, ip: ip)
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
