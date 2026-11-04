import Foundation
import ClaudexBarCore

/// Keeps each provider's last good snapshot across restarts, so the tray has
/// something to show (dimmed) while a provider can't be reached right after
/// launch, instead of a bare "net".
enum SnapshotStore {
    private static let key = "lastSnapshots.v1"

    private struct StoredWindow: Codable {
        let label: String
        let remaining: Int
        let resetAt: Date?
        let duration: TimeInterval?
        let title: String?
        let displayValue: String?
        let availabilityOnly: Bool

        init(_ w: UsageWindow) {
            label = w.windowLabel; remaining = w.remainingPercent; resetAt = w.resetAt
            duration = w.windowDuration; title = w.title; displayValue = w.displayValue
            availabilityOnly = w.availabilityOnly
        }

        var window: UsageWindow {
            UsageWindow(windowLabel: label, remainingPercent: remaining, resetAt: resetAt, windowDuration: duration,
                        title: title, displayValue: displayValue, availabilityOnly: availabilityOnly)
        }
    }

    private struct Stored: Codable {
        let primary: StoredWindow?
        let secondary: StoredWindow?
        let extra: [StoredWindow]
        let fetchedAt: Date
        let plan: String?
    }

    static func load(defaults: UserDefaults = .standard) -> [ProviderID: UsageSnapshot] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        var result: [ProviderID: UsageSnapshot] = [:]
        for (raw, s) in stored {
            guard let provider = ProviderID(rawValue: raw) else { continue }
            result[provider] = UsageSnapshot(primary: s.primary?.window, secondary: s.secondary?.window, fetchedAt: s.fetchedAt,
                                             extraWindows: s.extra.map(\.window), plan: s.plan)
        }
        return result
    }

    static func save(_ snapshots: [ProviderID: UsageSnapshot], defaults: UserDefaults = .standard) {
        let stored = snapshots.reduce(into: [String: Stored]()) { result, entry in
            let s = entry.value
            result[entry.key.rawValue] = Stored(primary: s.primary.map(StoredWindow.init), secondary: s.secondary.map(StoredWindow.init),
                                                extra: s.extraWindows.map(StoredWindow.init), fetchedAt: s.fetchedAt, plan: s.plan)
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }
}
