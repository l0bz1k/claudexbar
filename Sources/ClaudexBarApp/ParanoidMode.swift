import Foundation
import ClaudexBarCore

/// App-wide wiring for Paranoid Mode: the one gate every Claude/Codex
/// request, re-auth and auto-start anchor asks before it goes out.
enum ParanoidMode {
    static let gate = GeoGate(configuration: { AppSettings.paranoidConfiguration() })

    /// Blocked polls in a row after which the tray marks its numbers as no
    /// longer current (dimmed). Until then the last reading stays at full
    /// opacity and only the menu row says "geo".
    static let staleAfterBlockedPolls = 5

    /// An HTTP client for a provider whose traffic Paranoid Mode guards.
    static func gatedClient() -> any HTTPClient {
        GeoGatedHTTPClient(gate: gate)
    }
}
