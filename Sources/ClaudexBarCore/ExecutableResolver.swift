import Foundation

/// Finds a CLI the way the user's own shell would, for every place the app
/// runs one (checks, updates, auto-start, re-auth). An app started by launchd
/// gets a minimal PATH, so besides the inherited PATH this searches the usual
/// install locations (Homebrew, MacPorts, ~/.local/bin, Bun, Volta, pnpm, nvm,
/// mise/asdf shims, vendor installers) and the PATH of the user's login shell,
/// read once in the background.
public enum ExecutableResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginShellDirectories: [String]?
    nonisolated(unsafe) private static var loginShellCodexHome: String?

    /// `CODEX_HOME` as the user's login shell sets it (an app started by
    /// launchd doesn't inherit it). nil until read, or when unset.
    public static func cachedLoginShellCodexHome() -> String? {
        lock.withLock { loginShellCodexHome }
    }

    /// Directories to search, most specific first.
    public static func searchDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                         inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                         loginShell: [String]? = nil) -> [String] {
        let fileManager = FileManager.default
        var dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/pnpm",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.opencode/bin",
            "\(home)/.claude/local",
        ]
        // nvm: every installed node, newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        dirs += loginShell ?? cachedLoginShellDirectories() ?? []
        dirs += inheritedPath.split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first executable named `name` in `extra` paths, then the search
    /// directories.
    public static func find(_ name: String, extra: [String] = [], directories: [String]? = nil) -> URL? {
        let fileManager = FileManager.default
        let candidates = extra + (directories ?? searchDirectories()).map { "\($0)/\(name)" }
        return candidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func cachedLoginShellDirectories() -> [String]? {
        lock.withLock { loginShellDirectories }
    }

    /// Reads the login shell's PATH once (in the background; it can take a
    /// moment). Until it's known, the other locations are searched.
    public static func warmUp() {
        guard cachedLoginShellDirectories() == nil else { return }
        Task.detached(priority: .utility) {
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let result = await ProcessRunner.run(
                executable: URL(fileURLWithPath: shell),
                arguments: ["-l", "-c", #"printf '%s\n%s' "$PATH" "$CODEX_HOME""#],
                environment: ProcessInfo.processInfo.environment,
                timeout: 10
            )
            let lines = result.succeeded ? result.stdout.components(separatedBy: "\n") : []
            let dirs = (lines.first ?? "").split(separator: ":")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.hasPrefix("/") }
            let codexHome = lines.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.withLock {
                loginShellDirectories = dirs
                loginShellCodexHome = (codexHome?.isEmpty ?? true) ? nil : codexHome
            }
        }
    }
}
