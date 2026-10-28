import AppKit
import ClaudexBarCore

/// Installs a release in place: download → verify → swap the bundle → relaunch.
///
/// Every step is checked, and anything unexpected aborts *before* the
/// installed app is touched, so the worst case is "update didn't happen":
/// - the archive must hash to the release's published SHA-256;
/// - the unpacked app must carry the expected version and a valid signature;
/// - the old bundle is moved aside (not deleted) until the new one is in
///   place, and put back if the swap fails.
enum AppUpdater {
    enum Failure: Error, CustomStringConvertible {
        case noAssets
        case notWritable(URL)
        case download(String)
        case checksumMismatch
        case unpack
        case unexpectedBundle(String)
        case swap(String)

        var description: String {
            switch self {
            case .noAssets: return "the release has no downloadable app"
            case .notWritable(let url): return "can't write to \(url.deletingLastPathComponent().path)"
            case .download(let why): return "download failed (\(why))"
            case .checksumMismatch: return "the download didn't match the published SHA-256"
            case .unpack: return "couldn't unpack the archive"
            case .unexpectedBundle(let why): return "unexpected archive contents (\(why))"
            case .swap(let why): return "couldn't replace the app (\(why))"
            }
        }
    }

    /// Replaces the running app with `update`'s build. On success the new
    /// version is launched and this process terminates; it only returns on
    /// failure.
    @MainActor
    static func install(_ update: UpdateChecker.Update, logger: SanitizedLogger) async -> Failure? {
        guard let zipURL = update.zipURL, let checksumURL = update.checksumURL else { return .noAssets }

        let installed = Bundle.main.bundleURL
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            return .notWritable(installed)
        }

        let work = fileManager.temporaryDirectory.appendingPathComponent("ClaudexBar-Update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: work) }
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .unpack
        }

        // 1. Download archive and checksum, verify.
        let zipData: Data
        let checksumData: Data
        switch await download(zipURL) {
        case .success(let data): zipData = data
        case .failure(let why): return .download("archive: \(why)")
        }
        switch await download(checksumURL) {
        case .success(let data): checksumData = data
        case .failure(let why): return .download("checksum: \(why)")
        }
        guard UpdateChecker.matchesSHA256(zipData, checksumText: String(decoding: checksumData, as: UTF8.self)) else {
            return .checksumMismatch
        }
        let zipFile = work.appendingPathComponent(UpdateChecker.zipAssetName)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try zipData.write(to: zipFile)
        } catch {
            return .unpack
        }

        // 2. Unpack and check what's inside.
        let dittoResult = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zipFile.path, unpacked.path],
            timeout: 120
        )
        guard dittoResult.succeeded else { return .unpack }
        let newApp = unpacked.appendingPathComponent("ClaudexBar.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              (info["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
            return .unexpectedBundle("not ClaudexBar")
        }
        guard (info["CFBundleShortVersionString"] as? String) == update.latest else {
            return .unexpectedBundle("version is not \(update.latest)")
        }
        let verify = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", newApp.path],
            timeout: 60
        )
        guard verify.succeeded else { return .unexpectedBundle("signature check failed") }
        // Not downloaded by a browser, so normally not quarantined; make sure.
        _ = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", newApp.path],
            timeout: 30
        )

        // 3. Swap bundles, keeping the old one until the new one is in place.
        let backup = work.appendingPathComponent("ClaudexBar-previous.app", isDirectory: true)
        do {
            try fileManager.moveItem(at: installed, to: backup)
        } catch {
            return .swap("moving the current app aside: \(error.localizedDescription)")
        }
        do {
            try fileManager.moveItem(at: newApp, to: installed)
        } catch {
            try? fileManager.moveItem(at: backup, to: installed)
            return .swap("putting the new app in place: \(error.localizedDescription)")
        }
        logger.log(provider: .claude, message: "update: installed \(update.latest) (was \(update.current)), relaunching")
        logger.flush()
        // `defer` won't run: this process terminates below. Clean up now —
        // the previous version is no longer needed once the new one is in.
        try? fileManager.removeItem(at: work)

        // 4. Relaunch. The short pause lets macOS register the freshly
        //    copied bundle; launching it instantly can be refused with a
        //    "Launch Constraint Violation".
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        NSApp.terminate(nil)
        return nil
    }

    enum DownloadError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case .failed(let why) = self { return why }; return "" }
    }

    /// Up to three attempts with a growing pause. Proxied/VPN connections to
    /// GitHub drop now and then (resets, truncated responses), and a 404 can
    /// briefly appear while a release's assets are being re-uploaded.
    private static func download(_ url: URL, attempts: Int = 3) async -> Result<Data, DownloadError> {
        var request = URLRequest(url: url)
        request.setValue("ClaudexBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        var lastProblem = "no attempt made"
        for attempt in 1...attempts {
            do {
                let (data, response) = try await URLSession.claudexbar.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return .success(data) }
                lastProblem = "HTTP \(status)"
            } catch {
                let nsError = error as NSError
                lastProblem = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
        }
        return .failure(.failed("\(lastProblem), after \(attempts) attempts"))
    }
}
