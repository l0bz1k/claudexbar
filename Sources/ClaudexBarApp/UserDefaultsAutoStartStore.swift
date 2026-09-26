import Foundation
import ClaudexBarCore

/// Persists `AutoStartState` across app restarts — required so safety caps
/// (cooldown, daily limit, circuit breaker) survive a quit/relaunch instead
/// of resetting to a clean slate every time.
final class UserDefaultsAutoStartStore: AutoStartStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ provider: ProviderID) -> String {
        "autoStartState.\(provider.rawValue)"
    }

    func state(for provider: ProviderID) -> AutoStartState {
        guard let data = defaults.data(forKey: key(provider)),
              let decoded = try? JSONDecoder().decode(AutoStartState.self, from: data) else {
            return AutoStartState()
        }
        return decoded
    }

    func setState(_ state: AutoStartState, for provider: ProviderID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(provider))
    }
}
