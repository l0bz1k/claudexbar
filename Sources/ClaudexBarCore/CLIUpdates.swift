import Foundation

public struct CLIUpdateSnapshot: Sendable, Equatable {
    public let installed: [ProviderID: String]
    public let latest: [ProviderID: String]

    public init(installed: [ProviderID: String], latest: [ProviderID: String]) {
        self.installed = installed
        self.latest = latest
    }

    public func hasUpdate(for provider: ProviderID) -> Bool {
        guard let installed = installed[provider], let latest = latest[provider] else {
            return false
        }
        return UpdateChecker.isVersion(latest, newerThan: installed)
    }

    public var hasAnyUpdate: Bool {
        ProviderID.allCases.contains(where: hasUpdate)
    }
}

public enum CLIVersionParser {
    public static func semanticVersion(in text: String) -> String? {
        let pattern = #"(?<![0-9])v?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    /// The newest stable release in a GitHub releases list, restricted to the
    /// installed major version when known. opencode publishes 1.x and 2.x
    /// side by side, and its 1.x updater (`opencode upgrade`) never crosses
    /// to 2.x without `--major` — so a 2.x release is not an update for a
    /// 1.x install, and must not turn the badge orange.
    public static func newestRelease(from data: Data, sameMajorAs installed: String?) -> String? {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let major = installed.flatMap { $0.split(separator: ".").first.map(String.init) }
        let versions = releases.compactMap { release -> String? in
            guard (release["prerelease"] as? Bool) != true, (release["draft"] as? Bool) != true,
                  let tag = release["tag_name"] as? String,
                  tag.range(of: #"^v?\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                  let version = semanticVersion(in: tag) else { return nil }
            if let major, version.split(separator: ".").first.map(String.init) != major { return nil }
            return version
        }
        return versions.max { UpdateChecker.isVersion($1, newerThan: $0) }
    }

    public static func latestVersion(provider: ProviderID, from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .claude:
            guard let tag = root["tag_name"] as? String else { return nil }
            return semanticVersion(in: tag)
        case .codex:
            guard let version = root["version"] as? String else { return nil }
            return semanticVersion(in: version)
        case .opencodeFree:
            guard let tag = root["tag_name"] as? String else { return nil }
            return semanticVersion(in: tag)
        case .openrouter, .opencodeGo:
            return nil // API-key providers: no CLI of their own to update
        }
    }
}

public struct CLILatestVersionChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .claudexbar) {
        self.session = session
    }

    public func fetchLatestVersions(installed: [ProviderID: String] = [:]) async -> [ProviderID: String] {
        await withTaskGroup(of: (ProviderID, String?).self) { group in
            for provider in ProviderID.allCases where provider.hasCLI {
                group.addTask {
                    (provider, await latestVersion(for: provider, installed: installed[provider]))
                }
            }

            var versions: [ProviderID: String] = [:]
            for await (provider, version) in group {
                versions[provider] = version
            }
            return versions
        }
    }

    private func latestVersion(for provider: ProviderID, installed: String?) async -> String? {
        let urlString: String
        switch provider {
        case .claude:
            urlString = "https://api.github.com/repos/anthropics/claude-code/releases/latest"
        case .codex:
            urlString = "https://registry.npmjs.org/%40openai%2Fcodex/latest"
        case .opencodeFree:
            urlString = "https://api.github.com/repos/anomalyco/opencode/releases?per_page=50"
        case .openrouter, .opencodeGo:
            return nil
        }
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent")
        if provider == .claude || provider == .opencodeFree {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return nil
        }
        if provider == .opencodeFree {
            return CLIVersionParser.newestRelease(from: data, sameMajorAs: installed)
        }
        return CLIVersionParser.latestVersion(provider: provider, from: data)
    }
}
