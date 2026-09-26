import Foundation
import ClaudexBarCore

final class SanitizedLogger {
    static let shared = SanitizedLogger()

    private let logURL = AppPaths.logs.appendingPathComponent("claudexbar.log")
    private let rotatedURL = AppPaths.logs.appendingPathComponent("claudexbar.log.1")
    private let queue = DispatchQueue(label: "ClaudexBar.SanitizedLogger")
    /// Only ever touched on `queue`, so a single shared instance is safe.
    private let timestampFormatter = ISO8601DateFormatter()

    func log(provider: ProviderID, message: String) {
        // Defense-in-depth: scrub any secret-shaped substring before it is
        // ever written, even though callers only pass static status strings.
        let safeMessage = SecretScanner.redact(message)
        let now = Date()
        queue.async {
            AppPaths.ensureDirectories()
            self.rotateIfNeeded()
            let line = "\(self.timestampFormatter.string(from: now)) \(provider.rawValue) \(safeMessage)\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: self.logURL.path),
               let handle = try? FileHandle(forWritingTo: self.logURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.logURL, options: .atomic)
            }
        }
    }

    /// Keeps one previous generation (`claudexbar.log.1`) so the log never
    /// grows without bound but recent history survives a rotation.
    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard let size = (try? fileManager.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
              size > AppPaths.maxLogBytes else { return }
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: logURL, to: rotatedURL)
    }

    func flush() {
        queue.sync {}
    }
}
