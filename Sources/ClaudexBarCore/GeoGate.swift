import Foundation
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
        return Locale.isoRegionCodes.contains(code)
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

    public init(source: String, country: String?, failure: String? = nil) {
        self.source = source
        self.country = country
        self.failure = failure
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
    var url: URL { get }
    /// The ISO country code in a successful response body, or nil.
    func parseCountry(_ body: Data) -> String?
}

/// `https://1.1.1.1/cdn-cgi/trace`: plain `key=value` lines, `loc=NL`.
public struct CloudflareTraceGeoSource: GeoIPSource {
    public let name = "1.1.1.1"
    public let url = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    public init() {}

    public func parseCountry(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("loc=") {
            return CountryCode.normalize(String(line.dropFirst(4)))
        }
        return nil
    }
}

/// `https://ipinfo.io/country`: the bare code, `NL\n`.
public struct IPInfoGeoSource: GeoIPSource {
    public let name = "ipinfo.io"
    public let url = URL(string: "https://ipinfo.io/country")!

    public init() {}

    public func parseCountry(_ body: Data) -> String? {
        CountryCode.normalize(String(data: body, encoding: .utf8))
    }
}

// MARK: - Gate

public actor GeoGate {
    public static let defaultSources: [any GeoIPSource] = [CloudflareTraceGeoSource(), IPInfoGeoSource()]

    private let configuration: @Sendable () -> ParanoidConfiguration?
    private let sources: [any GeoIPSource]
    private let httpClient: any HTTPClient
    private let cacheTTL: TimeInterval
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
    public init(
        configuration: @escaping @Sendable () -> ParanoidConfiguration?,
        sources: [any GeoIPSource] = GeoGate.defaultSources,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        cacheTTL: TimeInterval = 20,
        timeout: TimeInterval = 6,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.sources = sources
        self.httpClient = httpClient
        self.cacheTTL = cacheTTL
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
            let observations = await currentObservations()
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

    private func currentObservations() async -> [GeoObservation] {
        if let cached, cached.generation == generation, now().timeIntervalSince(cached.at) < cacheTTL {
            return cached.observations
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
        var request = URLRequest(url: source.url)
        request.timeoutInterval = timeout
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let response = try await httpClient.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                return GeoObservation(source: source.name, country: nil, failure: "HTTP \(response.statusCode)")
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
