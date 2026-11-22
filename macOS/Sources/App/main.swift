import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let control = ControlServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance.
        if let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
            NSApp.terminate(nil); return
        }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.start()
            statusController = StatusItemController(model: model)
        }
        control.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // swiftdrop://launch — used by the Share Extension to start the app.
        // swiftdrop://show    — opens the menu bar popover.
        if urls.contains(where: { $0.host == "show" }) {
            MainActor.assumeIsolated { statusController?.showPopover() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

signal(SIGPIPE, SIG_IGN)   // a peer closing mid-write must be an error, not a crash
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
