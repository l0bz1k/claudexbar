import Foundation
import Security
import os

public protocol CodexAuthReading: Sendable {
    func readAccessToken() throws -> String
    /// The ChatGPT account/workspace the token belongs to, if known. Sent as
    /// `chatgpt-account-id` so users with several workspaces (e.g. personal
    /// plus Team/Business) see the limits of the account Codex actually uses,
    /// not whatever the backend picks as default.
    func readAccountID() -> String?
}

extension CodexAuthReading {
    public func readAccountID() -> String? { nil }
}

public struct CodexAuthReader: CodexAuthReading {
    private let authURL: URL

    public init(authURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")) {
        self.authURL = authURL
    }

    public func readAccessToken() throws -> String {
        guard let tokens = readTokens(),
              let token = tokens["access_token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw UsageError.missingAuth
        }

        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func readAccountID() -> String? {
        guard let id = readTokens()?["account_id"] as? String else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readTokens() -> [String: Any]? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["tokens"] as? [String: Any]
    }
}

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Int?

    public init(accessToken: String, refreshToken: String?, expiresAt: Int?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Where a Claude credential came from — which decides what ClaudexBar may do
/// with it.
public enum ClaudeCredentialSource: String, Sendable {
    case environment
    /// ClaudexBar's own OAuth session ("Re-authenticate" in the menu).
    case claudexbar
    /// Claude Code's login (its Keychain item or ~/.claude/.credentials.json).
    case claudeCode

    /// Only ClaudexBar's own session may be refreshed. Claude rotates the
    /// refresh token on every refresh, so refreshing Claude Code's credential
    /// would silently invalidate the copy Claude Code still holds — two apps
    /// sharing one session, each knocking the other out.
    public var mayRefresh: Bool { self == .claudexbar }
}

public struct ClaudeCredentialCandidate: Sendable {
    public let credentials: ClaudeCredentials
    public let source: ClaudeCredentialSource

    public init(credentials: ClaudeCredentials, source: ClaudeCredentialSource) {
        self.credentials = credentials
        self.source = source
    }
}

/// Reads one credential source on demand.
public struct ClaudeCredentialLoader: Sendable {
    public let source: ClaudeCredentialSource
    public let load: @Sendable () -> ClaudeCredentials?

    public init(source: ClaudeCredentialSource, load: @escaping @Sendable () -> ClaudeCredentials?) {
        self.source = source
        self.load = load
    }
}

public protocol ClaudeCredentialReading: Sendable {
    func readCredentials() throws -> ClaudeCredentials
    /// Every usable credential, most preferred first. Reads all sources.
    func credentialCandidates() -> [ClaudeCredentialCandidate]
    /// The same sources, in the same order, but *not yet read*: callers read
    /// the next one only if the previous didn't work out. Reading Claude
    /// Code's Keychain item when it isn't needed costs a password prompt every
    /// time Claude Code rewrites that item (which resets its access list).
    func credentialLoaders() -> [ClaudeCredentialLoader]
    /// Drop ClaudexBar's own session after the server definitively rejected
    /// its refresh token, so it stops shadowing a valid Claude Code login.
    func discardOwnedCredentials()
}

extension ClaudeCredentialReading {
    public func credentialLoaders() -> [ClaudeCredentialLoader] {
        credentialCandidates().map { candidate in
            ClaudeCredentialLoader(source: candidate.source) { candidate.credentials }
        }
    }

    public func credentialCandidates() -> [ClaudeCredentialCandidate] {
        (try? readCredentials()).map { [ClaudeCredentialCandidate(credentials: $0, source: .claudexbar)] } ?? []
    }

    public func discardOwnedCredentials() {}
}

public struct ClaudeCredentialReader: ClaudeCredentialReading {
    private let keychainServices: [String]
    private let fallbackURL: URL
    private let environment: [String: String]
    private let credentialStore: ClaudeCredentialStore

    public init(
        keychainServices: [String] = ["Claude Code-credentials"],
        fallbackURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: ClaudeCredentialStore = ClaudeCredentialStore()
    ) {
        self.keychainServices = keychainServices
        self.fallbackURL = fallbackURL
        self.environment = environment
        self.credentialStore = credentialStore
    }

    public func readCredentials() throws -> ClaudeCredentials {
        for loader in credentialLoaders() {
            if let credentials = loader.load() { return credentials }
        }
        throw UsageError.missingAuth
    }

    /// Explicit override first, then ClaudexBar's own session, then Claude
    /// Code's login. All of them are returned (not just the first) so a dead
    /// own session can't hide a perfectly good, freshly renewed Claude Code
    /// login — the situation after `claude login` that previously left the
    /// app stuck on "auth".
    public func credentialCandidates() -> [ClaudeCredentialCandidate] {
        credentialLoaders().compactMap { loader in
            loader.load().map { ClaudeCredentialCandidate(credentials: $0, source: loader.source) }
        }
    }

    public func credentialLoaders() -> [ClaudeCredentialLoader] {
        let environment = self.environment
        let store = credentialStore
        let fallbackURL = self.fallbackURL
        var loaders = [
            ClaudeCredentialLoader(source: .environment) { try? Self.credentialsFromEnvironment(environment) },
            ClaudeCredentialLoader(source: .claudexbar) { store.load() }
        ]
        for service in keychainServices {
            loaders.append(ClaudeCredentialLoader(source: .claudeCode) { [self] in
                keychainData(service: service).flatMap(Self.decodeCredentials(data:))
            })
        }
        loaders.append(ClaudeCredentialLoader(source: .claudeCode) {
            (try? Data(contentsOf: fallbackURL)).flatMap(Self.decodeCredentials(data:))
        })
        return loaders
    }

    public func discardOwnedCredentials() {
        credentialStore.clear()
    }

    public static func credentialsFromEnvironment(_ environment: [String: String]) throws -> ClaudeCredentials {
        guard let token = environment["CLAUDE_CODE_OAUTH_TOKEN"].map(stripBearerPrefix),
              !token.isEmpty
        else {
            throw UsageError.missingAuth
        }

        return ClaudeCredentials(accessToken: token, refreshToken: nil, expiresAt: nil)
    }

    public static func decodeCredentials(data: Data) -> ClaudeCredentials? {
        let decodedData: Data
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["claudeAiOauth"] != nil {
            decodedData = data
        } else if let text = String(data: data, encoding: .utf8),
                  let hexData = decodeHexOrJSONText(text) {
            decodedData = hexData
        } else {
            return nil
        }

        guard let root = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let rawAccessToken = oauth["accessToken"] as? String
        else {
            return nil
        }

        return ClaudeCredentials(
            accessToken: stripBearerPrefix(rawAccessToken),
            refreshToken: (oauth["refreshToken"] as? String).flatMap(stripBearerPrefix),
            expiresAt: oauth["expiresAt"] as? Int
        )
    }

    private func keychainData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        KeychainDiagnostics.noteReadStatus(status, service: service)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func decodeHexOrJSONText(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        var hex = trimmed
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        guard hex.count % 2 == 0 else { return nil }

        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public func stripBearerPrefix(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("bearer ") {
        return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// Surfaces Keychain read failures that are *not* a plain "item not found".
///
/// Callers deliberately fall back to the next credential source when a read
/// fails, which is right — but previously every failure (access denied by the
/// item's ACL, keychain locked, corrupt item) was indistinguishable from
/// "not installed", making real problems invisible. Those now go to the
/// unified log: `log show --predicate 'subsystem == "com.ipang.claudexbar"'`.
enum KeychainDiagnostics {
    private static let logger = os.Logger(subsystem: "com.ipang.claudexbar", category: "keychain")

    static func noteReadStatus(_ status: OSStatus, service: String) {
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        logger.error("Keychain read failed for \(service, privacy: .public): \(status) \(message, privacy: .public)")
    }
}
