import Foundation

public enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case claude
    case openrouter
    case opencodeGo = "opencode-go"
    case opencodeFree = "opencode-free"

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .openrouter: return "OpenRouter"
        case .opencodeGo: return "OpenCode Go"
        case .opencodeFree: return "OpenCode Free"
        }
    }

    /// Providers backed by a coding CLI with its own login and rolling
    /// session windows (Codex, Claude Code). Only these get CLI updates,
    /// "Auto-start 5h Session" and in-app re-authentication; the API-key
    /// providers (OpenRouter, OpenCode Go) are read with a key opencode stores.
    public var isCodingCLI: Bool {
        self == .codex || self == .claude
    }

    /// Providers whose row shows an installed CLI's version: Codex, Claude
    /// Code, and opencode (on its own free-tier row).
    public var hasCLI: Bool {
        isCodingCLI || self == .opencodeFree
    }

    /// Off unless the user turns them on, so existing setups don't start
    /// showing (or erroring on) providers they never asked for.
    public var enabledByDefault: Bool { isCodingCLI }
}

public struct ShellCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public var terminalCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_\-./:]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    func fetchUsage() async -> Result<UsageSnapshot, UsageError>
    func reauthCommand() -> ShellCommand
}

public struct UsageSnapshot: Equatable, Sendable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let fetchedAt: Date
    /// Windows that don't fit the two tray columns (e.g. OpenCode Go's third
    /// limit). Shown in the tooltip and diagnostics only.
    public let extraWindows: [UsageWindow]

    public init(primary: UsageWindow?, secondary: UsageWindow?, fetchedAt: Date, extraWindows: [UsageWindow] = []) {
        self.primary = primary
        self.secondary = secondary
        self.fetchedAt = fetchedAt
        self.extraWindows = extraWindows
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let windowLabel: String
    public let remainingPercent: Int
    public let resetAt: Date?
    /// Full length of the window (e.g. 5h, 7d, 30d), when the provider tells
    /// us. Needed to know how much of the window has *elapsed*, for pace.
    public let windowDuration: TimeInterval?
    /// Human name for tooltips ("Free-model requests today"); nil means the
    /// generic session/weekly naming.
    public let title: String?
    /// Shown instead of a percentage when there is no honest number to show
    /// (e.g. "ok" for a free tier that never reports how much is left).
    public let displayValue: String?

    public init(windowLabel: String, remainingPercent: Int, resetAt: Date?, windowDuration: TimeInterval? = nil, title: String? = nil, displayValue: String? = nil) {
        self.windowLabel = windowLabel
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetAt = resetAt
        self.windowDuration = windowDuration
        self.title = title
        self.displayValue = displayValue
    }

    public var usedPercent: Int { 100 - remainingPercent }
}

public enum UsageError: Error, Equatable, Sendable {
    case missingAuth
    case authExpired
    case network
    case rateLimited
    case server(statusCode: Int)
    case decoding
    case keychain
    case refreshFailed
    /// The provider's CDN (Cloudflare) refused this network, typically the
    /// exit IP of a VPN/proxy. Not the API, and not the credential.
    case blockedByEdge(ip: String?)

    public var statusLabel: String {
        switch self {
        case .missingAuth, .authExpired, .refreshFailed:
            return "auth"
        case .network, .rateLimited:
            return "net"
        case .server, .decoding, .keychain:
            return "err"
        case .blockedByEdge:
            return "vpn"
        }
    }

    /// Transient errors (network blips, rate limits, server hiccups) where a
    /// recently-fetched snapshot is still worth showing rather than blanking
    /// the pill to a status word.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .server:
            return true
        // A block persists until the route changes; showing stale numbers
        // without saying so would hide that.
        case .missingAuth, .authExpired, .refreshFailed, .decoding, .keychain, .blockedByEdge:
            return false
        }
    }

    public var sanitizedDescription: String {
        switch self {
        case .missingAuth:
            return "Missing CLI authentication"
        case .authExpired:
            return "CLI authentication expired"
        case .network:
            return "Network request failed"
        case .rateLimited:
            return "Usage endpoint rate limited"
        case .server(let statusCode):
            return "Usage endpoint returned HTTP \(statusCode)"
        case .decoding:
            return "Usage response could not be parsed"
        case .keychain:
            return "Credential lookup failed"
        case .refreshFailed:
            return "Credential refresh failed"
        case .blockedByEdge(let ip):
            let address = ip.map { " IP \($0)" } ?? " this network's IP"
            return "Blocked by Cloudflare for\(address) — likely the VPN/proxy exit; try another node"
        }
    }
}

public enum UsageWindowKind: String, Hashable, Sendable {
    case primary
    case secondary
}

public struct WindowDisplay: Equatable, Sendable {
    public let label: String
    public let remainingPercent: Int
}

public struct UsageMetricDisplay: Equatable, Sendable {
    public let label: String
    public let value: String
}

public extension ISO8601DateFormatter {
    static let claudex: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let claudexNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseClaudexDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return claudex.date(from: value) ?? claudexNoFraction.date(from: value)
    }
}

public func clampPercent(_ value: Double) -> Int {
    max(0, min(100, Int(value.rounded())))
}

public func clampPercent(_ value: Int) -> Int {
    max(0, min(100, value))
}
