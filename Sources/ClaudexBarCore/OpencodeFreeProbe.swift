import Foundation
import SQLite3

/// Checks whether opencode's free tier answers again, by asking it — through
/// the real `opencode` binary, so the request is exactly what a user's own
/// opencode would send and goes the same way through any proxy.
///
/// It runs in a separate, clean profile (its own config/data/cache dirs):
/// none of the user's plugins (a fallback plugin could silently switch to
/// another model and report a false "ready"), MCP servers or provider keys,
/// and nothing lands in the user's history. Only the `opencode` provider's
/// free models are ever asked, by explicit `opencode/<model>`.
///
/// Free models come and go, so the model is chosen every time: the one the
/// user last tried, else their most used one this week, else any free model in
/// the current catalog — always confirmed against the catalog that the
/// installed opencode itself reports.
public enum OpencodeFreeProbe {
    public enum Outcome: String, Sendable {
        case ready, blocked, modelMissing, inconclusive
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudexBar/opencode-probe")
    }
    public static var dataDirectory: URL { directory.appendingPathComponent("data") }
    public static var logURL: URL { dataDirectory.appendingPathComponent("opencode/log/opencode.log") }
    public static var databaseURL: URL { dataDirectory.appendingPathComponent("opencode/opencode.db") }
    /// The free models of the last catalog read, one id per line.
    public static var catalogURL: URL { directory.appendingPathComponent("free-models.txt") }

    /// The environment that makes `opencode` use the clean profile. Variables
    /// that point opencode at other config, data or credentials (OPENCODE_*)
    /// are dropped, so nothing of the user's setup leaks in; proxy and
    /// certificate settings stay, so the check takes the user's own route.
    public static func environment(base: [String: String]) -> [String: String] {
        base.filter { !$0.key.hasPrefix("OPENCODE_") }.merging([
            "XDG_CONFIG_HOME": directory.appendingPathComponent("config").path,
            "XDG_DATA_HOME": dataDirectory.path,
            "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path,
            "XDG_STATE_HOME": directory.appendingPathComponent("state").path,
        ]) { _, new in new }
    }

    /// Deliberately minimal: no custom agent or tool restrictions (the free
    /// tier refuses clients whose basic tools are denied), nothing that differs
    /// between opencode 1.x and 2.x.
    public static let config = """
    {
      "$schema": "https://opencode.ai/config.json",
      "autoupdate": false,
      "share": "disabled"
    }
    """

    public static let prompt = "Reply with exactly: ready"

    /// Fallback test for "free" while there is no catalog yet. Free models
    /// are defined by price, not name (`big-pickle` is free), so this is only
    /// a stopgap.
    public static func looksFree(_ model: String) -> Bool {
        model.hasSuffix("-free")
    }

    /// `opencode models opencode --verbose` output (each `opencode/<id>` line
    /// followed by the model's JSON) → the models that cost nothing and aren't
    /// deprecated. Plain output (no JSON) falls back to the `-free` suffix.
    public static func freeModels(fromCatalog output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        var models: [String] = []
        var index = 0
        var sawJSON = false
        while index < lines.count {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard text.hasPrefix("opencode/"), !text.contains(" ") else { continue }
            let model = String(text.dropFirst("opencode/".count))
            // Collect the JSON block that follows, if any.
            var block: [String] = []
            if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "{" {
                var depth = 0
                while index < lines.count {
                    let line = lines[index]
                    block.append(line)
                    depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                    index += 1
                    if depth <= 0 { break }
                }
            }
            if !block.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: Data(block.joined(separator: "\n").utf8)) as? [String: Any] {
                sawJSON = true
                let cost = json["cost"] as? [String: Any]
                let input = (cost?["input"] as? NSNumber)?.doubleValue
                let outputCost = (cost?["output"] as? NSNumber)?.doubleValue
                let deprecated = (json["status"] as? String)?.lowercased() == "deprecated"
                if input == 0, outputCost == 0, !deprecated { models.append(model) }
            } else if !sawJSON, looksFree(model) {
                models.append(model)
            }
        }
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    public static func saveCatalog(_ models: [String], to url: URL = catalogURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (models.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// nil: no catalog has been read yet.
    public static func loadCatalog(from url: URL = catalogURL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let models = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return models.isEmpty ? nil : models
    }

    public static func catalogAge(of url: URL = catalogURL, now: Date = Date()) -> TimeInterval? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(modified)
    }

    /// The model to ask: the first preferred one (the user's current model
    /// first) that the catalog still lists; else any free model in it. Without
    /// a catalog, the first preferred one.
    public static func chooseModel(recent: [String], catalog: [String], unavailable: Set<String>) -> String? {
        let usable = { (model: String) in !unavailable.contains(model) }
        guard !catalog.isEmpty else { return recent.first(where: usable) }
        let listed = Set(catalog)
        return recent.first { listed.contains($0) && usable($0) } ?? catalog.first(where: usable)
    }

    /// Reads what happened from the probe's own log lines (written after the
    /// probe started) and the process result.
    public static func classify(newLog: String, stdout: String, exitCode: Int32) -> Outcome {
        if newLog.contains("Free usage") { return .blocked }
        let lower = newLog.lowercased()
        if lower.contains("modelnotfound") || lower.contains("model not found") || lower.contains("providermodelnotfound") {
            return .modelMissing
        }
        if exitCode == 0, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
        return .inconclusive
    }

    /// True once the probe's log has the server's answer, so opencode (which
    /// would otherwise retry a refusal for hours) can be stopped.
    public static func logHasVerdict(_ newLog: String) -> Bool {
        newLog.contains("Free usage") || newLog.lowercased().contains("modelnotfound")
    }

    /// When the next check is due: an hour after the latest evidence (anyone's
    /// refusal, or the last check); after checks that couldn't tell, sooner —
    /// 15, 30, 60 min.
    public static func nextCheck(lastRefusal: Date?, lastCheck: Date?, inconclusiveStreak: Int) -> Date {
        let interval: TimeInterval = inconclusiveStreak > 0
            ? min(3600, 900 * pow(2, Double(inconclusiveStreak - 1)))
            : 3600
        let base = [lastRefusal, lastCheck].compactMap { $0 }.max() ?? .distantPast
        return base.addingTimeInterval(interval)
    }

    // MARK: helpers

    static func tail(of url: URL, bytes: Int = 1_000_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Bytes written to `url` after `offset`.
    public static func contents(of url: URL, after offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return "" }
        try? handle.seek(toOffset: offset)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func size(of url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    /// The user's `opencode`-provider models by use since `since`, most used
    /// first (paid ones included; callers filter to free models).
    public static func mostUsed(databaseURL: URL, since: Date) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(databaseURL.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = """
        SELECT json_extract(data, '$.modelID') AS model, COUNT(*) AS n FROM message
        WHERE time_created > ? AND json_extract(data, '$.providerID') = 'opencode'
          AND json_extract(data, '$.role') = 'assistant'
        GROUP BY model ORDER BY n DESC LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        var models: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            models.append(String(cString: text))
        }
        return models
    }
}
