import CryptoKit
import Foundation

/// Asks GitHub for the latest release of this fork and compares it to the
/// running version. No Sparkle, no extra dependency, no hosted appcast: the
/// release itself carries `ClaudexBar.zip` and `ClaudexBar.zip.sha256`, which
/// is everything an in-place update needs.
public struct UpdateChecker: Sendable {
    /// The repo whose releases this build updates from. Must be the fork:
    /// pointing at upstream would offer users an "update" that drops every
    /// patch in this build.
    public static let repoSlug = "l0bz1k/claudexbar"
    public static let zipAssetName = "ClaudexBar.zip"
    public static let checksumAssetName = "ClaudexBar.zip.sha256"

    public struct Update: Sendable, Equatable {
        public let latest: String
        public let current: String
        public let releaseURL: URL?
        /// The app archive and its published checksum; nil when the release
        /// lacks them (then only the release page can be offered).
        public let zipURL: URL?
        public let checksumURL: URL?
        /// Release notes (Markdown), possibly empty.
        public let notes: String

        public var isNewer: Bool { UpdateChecker.isVersion(latest, newerThan: current) }
        public var canInstallInPlace: Bool { zipURL != nil && checksumURL != nil }
    }

    private let session: URLSession

    public init(session: URLSession = .claudexbar) {
        self.session = session
    }

    public func latestRelease(currentVersion: String) async -> Update? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent") // GitHub requires a UA
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return Self.parseRelease(data, currentVersion: currentVersion)
    }

    /// Parses a GitHub "latest release" payload.
    public static func parseRelease(_ data: Data, currentVersion: String) -> Update? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            return nil
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        func assetURL(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        return Update(
            latest: latest,
            current: currentVersion,
            releaseURL: (root["html_url"] as? String).flatMap(URL.init(string:)),
            zipURL: assetURL(zipAssetName),
            checksumURL: assetURL(checksumAssetName),
            notes: (root["body"] as? String) ?? ""
        )
    }

    /// True when `data` hashes to the SHA-256 in `checksumText` — the
    /// `shasum -a 256` format ("<hex>  <file>") or a bare hex digest.
    public static func matchesSHA256(_ data: Data, checksumText: String) -> Bool {
        guard let expected = checksumText
            .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
            .first.map({ $0.lowercased() }),
              expected.count == 64 else {
            return false
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    /// Numeric dotted-version comparison (e.g. "0.10.0" > "0.9.0"). Non-numeric
    /// components are treated as 0.
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
