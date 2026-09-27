import Foundation
import ClaudexBarCore

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    func removeLegacyCodexAccountSettings() {
        [
            "activeCodexAccountID",
            "enabledCodexAccountIDs",
            "hiddenCodexAccountIDs"
        ].forEach(defaults.removeObject(forKey:))
    }

    var activeProvider: ProviderID {
        get {
            ProviderID(rawValue: defaults.string(forKey: "activeProvider") ?? "") ?? .codex
        }
        set {
            defaults.set(newValue.rawValue, forKey: "activeProvider")
        }
    }

    var enabledProviders: [ProviderID] {
        get {
            guard let rawValues = defaults.array(forKey: "enabledProviders") as? [String] else {
                return ProviderID.allCases
            }
            let providers = rawValues.compactMap(ProviderID.init(rawValue:))
            return ProviderID.allCases.filter { providers.contains($0) }
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: "enabledProviders")
        }
    }

    var refreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: "refreshInterval")
            return value > 0 ? value : 300
        }
        set {
            defaults.set(newValue, forKey: "refreshInterval")
        }
    }

    var notificationThreshold: NotificationThreshold {
        get {
            NotificationThreshold(rawValue: defaults.integer(forKey: "notificationThreshold")) ?? .twentyPercent
        }
        set {
            defaults.set(newValue.rawValue, forKey: "notificationThreshold")
        }
    }

    var smartSwitchEnabled: Bool {
        get {
            if defaults.object(forKey: "smartSwitchEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "smartSwitchEnabled")
        }
        set {
            defaults.set(newValue, forKey: "smartSwitchEnabled")
        }
    }

    var automaticCLIUpdatesEnabled: Bool {
        get {
            if defaults.object(forKey: "automaticCLIUpdatesEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "automaticCLIUpdatesEnabled")
        }
        set {
            defaults.set(newValue, forKey: "automaticCLIUpdatesEnabled")
        }
    }

    /// Opt-in, off by default: sends one trivial message through the real
    /// `claude`/`codex` CLI when that provider's 5-hour (or monthly) window
    /// looks idle/unstarted, so idle time before your first prompt isn't
    /// wasted. See SessionAutoStarter for the detection/safety logic.
    var autoStartClaudeEnabled: Bool {
        get { defaults.bool(forKey: "autoStartClaudeEnabled") }
        set { defaults.set(newValue, forKey: "autoStartClaudeEnabled") }
    }

    var autoStartCodexEnabled: Bool {
        get { defaults.bool(forKey: "autoStartCodexEnabled") }
        set { defaults.set(newValue, forKey: "autoStartCodexEnabled") }
    }

    /// Remaining (historical default) or used — the latter matches what the
    /// Claude and ChatGPT apps themselves show.
    var percentMode: PercentMode {
        get { PercentMode(rawValue: defaults.string(forKey: "percentMode") ?? "") ?? .remaining }
        set { defaults.set(newValue.rawValue, forKey: "percentMode") }
    }

    /// Pace warning (▲ next to a window's countdown when, at the current rate,
    /// the limit runs out before that window resets), per window, since they
    /// matter to different people: the short session window, and the long one
    /// (weekly for Claude, monthly on the Codex Go plan). Both default to the
    /// single 0.3.0 setting, which itself defaulted to on.
    var paceWarningSession: Bool {
        get { bool(forKey: "paceWarningSession", fallback: legacyPaceWarning) }
        set { defaults.set(newValue, forKey: "paceWarningSession") }
    }

    var paceWarningLong: Bool {
        get { bool(forKey: "paceWarningLong", fallback: legacyPaceWarning) }
        set { defaults.set(newValue, forKey: "paceWarningLong") }
    }

    private var legacyPaceWarning: Bool {
        bool(forKey: "paceWarningEnabled", fallback: true)
    }

    private func bool(forKey key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    func autoStartEnabled(for provider: ProviderID) -> Bool {
        switch provider {
        case .claude: return autoStartClaudeEnabled
        case .codex: return autoStartCodexEnabled
        }
    }

    func setAutoStartEnabled(_ enabled: Bool, for provider: ProviderID) {
        switch provider {
        case .claude: autoStartClaudeEnabled = enabled
        case .codex: autoStartCodexEnabled = enabled
        }
    }
}
