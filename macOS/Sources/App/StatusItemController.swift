import AppKit
import SwiftUI
import Combine

/// Menu bar icon: click for the popover, drop files/text onto it to send.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var dropView: StatusDropView!
    private var settingsWindow: NSWindow?
    private var observer: Any?

    init(model: AppModel) {
        self.model = model
        super.init()

        let host = NSHostingController(rootView: MenuView(model: model, controller: self))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.image = Self.icon(for: model.receiveMode)
            button.setAccessibilityLabel("SwiftDrop")
            dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onClick = { [weak self] in self?.togglePopover() }
            dropView.onDrop = { [weak self] payload in self?.receiveDrop(payload) }
            dropView.onDragHover = { [weak button] on in button?.highlight(on) }
            button.addSubview(dropView)
        }
        observer = model.$receiveMode.sink { [weak self] mode in
            self?.statusItem.button?.image = Self.icon(for: mode)
        }
    }

    private static func icon(for mode: ReceiveMode) -> NSImage? {
        let name = mode == .off ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "SwiftDrop")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        img?.isTemplate = true
        return img
    }

    func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.sendingUIDidAppear()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    func closePopover() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func receiveDrop(_ payload: OutgoingPayload) {
        model.pendingPayload = payload
        showPopover()
    }

    func openSettings() {
        closePopover()
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "SwiftDrop Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Lets the user pick files when a device is clicked with nothing queued.
    func pickFilesAndSend(to peerID: String) {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose items to send with SwiftDrop"
        panel.begin { [weak self] resp in
            guard resp == .OK, !panel.urls.isEmpty else { return }
            self?.model.send(OutgoingPayload(fileURLs: panel.urls), to: peerID)
            self?.showPopover()
        }
    }
}

/// Transparent view laid over the status bar button that accepts drags.
final class StatusDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((OutgoingPayload) -> Void)?
    var onDragHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragHover?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragHover?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDrop?(OutgoingPayload(fileURLs: urls)); return true
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            let f = AppPaths.newStageFile(named: "Image.png")
            if (try? png.write(to: f)) != nil { onDrop?(OutgoingPayload(fileURLs: [f])); return true }
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            onDrop?(OutgoingPayload(texts: [s])); return true
        }
        return false
    }
}
