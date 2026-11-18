import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()
        controller = StatusBarController()
        controller?.start()
    }
}
