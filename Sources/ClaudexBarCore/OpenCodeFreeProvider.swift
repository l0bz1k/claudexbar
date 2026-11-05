import Foundation
import SQLite3

/// opencode's own free tier (OpenCode Zen free models, provider `opencode`).
///
/// There is no usage API: the server only says "Free usage limit reached"
/// (HTTP 429, sometimes with `Retry-After`) when a request is refused, and
/// limits are kept **per model** — one free model can be refused while another
/// answers. So this provider gathers evidence per model from opencode's own
/// log and database (and those of ClaudexBar's availability check), read-only
/// and without any network:
///   - refusals: the log's `stream error … Free usage` lines, and stored 429s
///     (which carry `Retry-After`, i.e. an exact reset);
///   - answers: completed, error-free assistant messages of that same model.
/// Only an answer from the same model clears its refusal.
///
/// The headline is the model the user works with (their latest free-tier
/// request); other recently refused models go to the tooltip. Free models are
/// recognised by price from the catalog the availability check saves, falling
/// back to the `-free` suffix until there is one.
public struct OpenCodeFreeProvider: UsageProvider {
    public let id = ProviderID.opencodeFree
    public let displayName = ProviderID.opencodeFree.displayName

    private let databaseURL: URL
    private let logURL: URL
    /// The availability check's own profile (see `OpencodeFreeProbe`): its
    /// refusals and answers count as evidence just like the user's own.
    private let extraLogURLs: [URL]
    private let extraDatabaseURLs: [URL]
    private let catalogURL: URL
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
        extraLogURLs: [URL] = [OpencodeFreeProbe.logURL],
        extraDatabaseURLs: [URL] = [OpencodeFreeProbe.databaseURL],
        catalogURL: URL = OpencodeFreeProbe.catalogURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseURL = databaseURL
        self.logURL = logURL
        self.extraLogURLs = extraLogURLs
        self.extraDatabaseURLs = extraDatabaseURLs
        self.catalogURL = catalogURL
        self.now = now
    }

    public func reauthCommand() -> ShellCommand {
        ShellCommand("opencode", ["auth", "login"])
    }

    // MARK: - Evidence

    /// What is known about one free model.
    public struct ModelEvidence: Equatable, Sendable {
        public var lastRefusal: Date?
        /// From a stored 429 with `Retry-After`: when the server said it resets.
        public var resetAt: Date?
        public var lastAnswer: Date?

        public init(lastRefusal: Date? = nil, resetAt: Date? = nil, lastAnswer: Date? = nil) {
            self.lastRefusal = lastRefusal
            self.resetAt = resetAt
            self.lastAnswer = lastAnswer
        }

        /// The refusal still stands: no answer from this model since.
        public var isBlocked: Bool {
            guard let lastRefusal else { return false }
            return (lastAnswer ?? .distantPast) < lastRefusal
        }
    }

    public struct Evidence: Equatable, Sendable {
        /// The model the user works with: their latest free-tier request.
        public var currentModel: String?
        public var models: [String: ModelEvidence]

        public init(currentModel: String?, models: [String: ModelEvidence]) {
            self.currentModel = currentModel
            self.models = models
        }
    }

    /// The free-model ids the catalog lists (nil: no catalog saved yet).
    public func freeModels() -> Set<String>? {
        OpencodeFreeProbe.loadCatalog(from: catalogURL).map { Set($0) }
    }

    public func evidence() -> Evidence {
        let catalog = freeModels()
        let isFree: (String) -> Bool = { model in
            catalog.map { $0.contains(model) } ?? OpencodeFreeProbe.looksFree(model)
        }
        var models: [String: ModelEvidence] = [:]

        var current: String?
        for (index, url) in ([logURL] + extraLogURLs).enumerated() {
            let scan = Self.scanLog(url)
            for (model, date) in scan.refusals where isFree(model) {
                models[model, default: .init()].lastRefusal = max(models[model]?.lastRefusal ?? .distantPast, date)
            }
            // Only the user's own requests say which model they use.
            if index == 0 { current = scan.latestRequestModel.flatMap { isFree($0) ? $0 : nil } }
        }
        for url in [databaseURL] + extraDatabaseURLs {
            for (model, date) in Self.lastAnswers(databaseURL: url) where isFree(model) {
                models[model, default: .init()].lastAnswer = max(models[model]?.lastAnswer ?? .distantPast, date)
            }
            for refusal in Self.storedRefusals(databaseURL: url) where isFree(refusal.model) {
                var entry = models[refusal.model, default: .init()]
                entry.lastRefusal = max(entry.lastRefusal ?? .distantPast, refusal.at)
                if let reset = refusal.resetAt, reset > (entry.resetAt ?? .distantPast) { entry.resetAt = reset }
                models[refusal.model] = entry
            }
        }
        if current == nil {
            current = OpencodeFreeProbe.mostUsed(databaseURL: databaseURL, since: now().addingTimeInterval(-7 * 24 * 3600))
                .first(where: isFree)
        }
        return Evidence(currentModel: current, models: models)
    }

    /// The headline model and, if it's refused, when — what the next check is
    /// timed from.
    public func currentModelRefusal() -> (model: String?, refusal: Date?, lastAnswer: Date?) {
        let evidence = evidence()
        guard let model = evidence.currentModel, let entry = evidence.models[model] else {
            return (evidence.currentModel, nil, nil)
        }
        return (model, entry.isBlocked ? entry.lastRefusal : nil, entry.lastAnswer)
    }

    public func fetchUsage() async -> Result<UsageSnapshot, UsageError> {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .failure(.missingAuth) // opencode not installed / never run
        }
        return .success(Self.snapshot(evidence: evidence(), now: now()))
    }

    // MARK: - State

    /// How long an unconfirmed block is assumed to last at most.
    static let unconfirmedBlockLimit: TimeInterval = 24 * 60 * 60
    /// How long a refusal still counts as "blocked now". Apps that keep
    /// retrying (opencode 1.x every ~10 min) keep refreshing it.
    static let refusalEvidenceWindow: TimeInterval = 60 * 60

    public enum ModelState: Equatable, Sendable {
        case ready
        /// Refused; `until` when the server said when.
        case blocked(since: Date, until: Date?)
        /// Refused long enough ago, with nothing tried since, that it may well
        /// have reset.
        case unknown(since: Date)
    }

    public static func state(of entry: ModelEvidence?, now: Date) -> ModelState {
        guard let entry, entry.isBlocked, let refusal = entry.lastRefusal else { return .ready }
        if let reset = entry.resetAt, reset > refusal {
            return reset > now ? .blocked(since: refusal, until: reset) : .ready
        }
        let age = now.timeIntervalSince(refusal)
        if age < refusalEvidenceWindow { return .blocked(since: refusal, until: nil) }
        if age < unconfirmedBlockLimit { return .unknown(since: refusal) }
        return .ready
    }

    public static func snapshot(evidence: Evidence, now: Date) -> UsageSnapshot {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        func window(for model: String?) -> (window: UsageWindow, word: String) {
            let subject = model ?? "Free models"
            switch state(of: model.flatMap { evidence.models[$0] }, now: now) {
            case .ready:
                return (UsageWindow(windowLabel: "free", remainingPercent: 100, resetAt: nil,
                                    title: "\(subject): no limit hit (OpenCode doesn't report how much is left)",
                                    displayValue: "ready", availabilityOnly: true), "ready")
            case .blocked(let since, let until?):
                return (UsageWindow(windowLabel: "free", remainingPercent: 0, resetAt: until,
                                    title: "\(subject): limit reached at \(clock.string(from: since)), resumes in \(UsageFormatter.resetLabel(resetAt: until, now: now))", availabilityOnly: true), "blocked")
            case .blocked(let since, nil):
                return (UsageWindow(windowLabel: "free", remainingPercent: 0, resetAt: nil,
                                    title: "\(subject): limit reached at \(clock.string(from: since)); the server hasn't said when it resets", availabilityOnly: true), "blocked")
            case .unknown(let since):
                return (UsageWindow(windowLabel: "free", remainingPercent: 100, resetAt: nil,
                                    title: "\(subject): last refused at \(clock.string(from: since)), nothing tried since — may have reset; the next request will tell",
                                    displayValue: "?", availabilityOnly: true), "?")
            }
        }

        // Other free models refused within the last day, for the tooltip.
        let others = evidence.models
            .filter { $0.key != evidence.currentModel && $0.value.isBlocked
                && now.timeIntervalSince($0.value.lastRefusal ?? .distantPast) < unconfirmedBlockLimit }
            .keys.sorted()
            .map { model -> UsageWindow in
                let (w, word) = window(for: model)
                return UsageWindow(windowLabel: w.windowLabel, remainingPercent: w.remainingPercent, resetAt: w.resetAt,
                                   title: w.title, displayValue: word, availabilityOnly: true)
            }
        return UsageSnapshot(primary: window(for: evidence.currentModel).window, secondary: nil,
                             fetchedAt: now, extraWindows: others)
    }

    // MARK: - Reading opencode's files

    /// Latest refusal per model, and the model of the latest free-tier request.
    public static func scanLog(_ url: URL) -> (refusals: [String: Date], latestRequestModel: String?) {
        guard let text = OpencodeFreeProbe.tail(of: url) else { return ([:], nil) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var refusals: [String: Date] = [:]
        var latestModel: String?
        for line in text.split(separator: "\n") where line.contains("providerID=opencode ") {
            guard let model = field("modelID", in: line) else { continue }
            if line.contains("message=stream ") { latestModel = model }
            // opencode truncates long lines ("…Free usage limit reac"): match the
            // stable start of both phrasings ("limit reached", "exceeded").
            guard line.contains("stream error"), line.contains("Free usage"),
                  let stamp = field("timestamp", in: line),
                  let date = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { continue }
            refusals[model] = max(refusals[model] ?? .distantPast, date)
        }
        return (refusals, latestModel)
    }

    private static func field(_ name: String, in line: Substring) -> String? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let value = line[range.upperBound...].prefix { $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    private static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer?) -> T) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(url.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        return body(db)
    }

    /// Latest completed, error-free answer per `opencode` model.
    public static func lastAnswers(databaseURL: URL) -> [String: Date] {
        withDatabase(databaseURL) { db in
            let sql = """
            SELECT json_extract(data, '$.modelID'), MAX(time_created) FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.providerID') = 'opencode'
              AND json_extract(data, '$.time.completed') IS NOT NULL
              AND json_extract(data, '$.error') IS NULL
              AND COALESCE(json_extract(data, '$.tokens.output'), 0) > 0
            GROUP BY 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(statement) }
            var result: [String: Date] = [:]
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result[String(cString: text)] = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
            }
            return result
        } ?? [:]
    }

    public struct StoredRefusal: Equatable, Sendable {
        public let model: String
        public let at: Date
        public let resetAt: Date?
    }

    /// Free-tier 429s opencode saved (once it gave up retrying), newest first.
    public static func storedRefusals(databaseURL: URL, limit: Int = 50) -> [StoredRefusal] {
        withDatabase(databaseURL) { db in
            let sql = """
            SELECT data, time_created FROM message
            WHERE data LIKE '%"statusCode":429%' AND data LIKE '%Free usage%'
            ORDER BY time_created DESC LIMIT \(limit)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [StoredRefusal] = []
            while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                let json = String(cString: text)
                guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      (root["providerID"] as? String) == "opencode",
                      let model = root["modelID"] as? String else { continue }
                result.append(StoredRefusal(
                    model: model,
                    at: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000),
                    resetAt: resetDate(fromRefusal: json)
                ))
            }
            return result
        } ?? []
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
