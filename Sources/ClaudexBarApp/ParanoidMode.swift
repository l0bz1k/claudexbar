import Foundation
import ClaudexBarCore

/// App-wide wiring for Paranoid Mode: the one gate every Claude/Codex
/// request, re-auth and auto-start anchor asks before it goes out.
enum ParanoidMode {
    static let ipinfoToken = TokenCache()

    static let gate = GeoGate(
        configuration: { AppSettings.paranoidConfiguration() },
        sources: GeoGate.defaultSources(ipinfoToken: { ParanoidMode.ipinfoToken.current })
    )

    /// Blocked polls in a row after which the tray marks its numbers as no
    /// longer current (dimmed). Until then the last reading stays at full
    /// opacity and only the menu row says "geo".
    static let staleAfterBlockedPolls = 5

    /// An HTTP client for a provider whose traffic Paranoid Mode guards.
    static func gatedClient() -> any HTTPClient {
        GeoGatedHTTPClient(gate: gate)
    }

    /// The IPinfo token, read from the Keychain once and kept in memory, so
    /// a lookup never touches the Keychain.
    final class TokenCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var value: String?
        private let store = IPInfoTokenStore()

        var current: String? {
            lock.withLock {
                if !loaded {
                    value = store.load()
                    loaded = true
                }
                return value
            }
        }

        var isSet: Bool { current != nil }

        func set(_ token: String) throws {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(trimmed)
            lock.withLock {
                value = trimmed
                loaded = true
            }
        }

        func clear() {
            store.clear()
            lock.withLock {
                value = nil
                loaded = true
            }
        }
    }
}
