import Foundation

enum LaunchAgentManager {
    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.launchAgent.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private static func install() {
        guard let executable = Bundle.main.executableURL else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.ipang.claudexbar</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executable.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(AppPaths.logs.appendingPathComponent("claudexbar.out.log").path)</string>
          <key>StandardErrorPath</key>
          <string>\(AppPaths.logs.appendingPathComponent("claudexbar.err.log").path)</string>
        </dict>
        </plist>
        """
        AppPaths.ensureDirectories()
        try? FileManager.default.createDirectory(
            at: AppPaths.launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? plist.write(to: AppPaths.launchAgent, atomically: true, encoding: .utf8)
        // Re-enabling within the same login session: the job is still loaded
        // (uninstall no longer boots it out), and the plist on disk is all
        // that's needed for the next login.
        if !isJobLoaded {
            runLaunchctl(["bootstrap", "gui/\(getuid())", AppPaths.launchAgent.path])
        }
    }

    /// Only removes the plist — deliberately no `launchctl bootout`. When the
    /// app was started at login it *is* this job's process, so booting the job
    /// out terminated the app the instant "Launch at Login" was unchecked.
    /// The job has no KeepAlive, so a loaded-but-plistless job never restarts
    /// on its own, and without the plist it isn't started at the next login.
    private static func uninstall() {
        try? FileManager.default.removeItem(at: AppPaths.launchAgent)
    }

    private static var isJobLoaded: Bool {
        runLaunchctl(["print", "gui/\(getuid())/com.ipang.claudexbar"]) == 0
    }

    /// Synchronous on purpose so callers can act on the exit status; launchctl
    /// returns almost instantly, so blocking here is harmless.
    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
