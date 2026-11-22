import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Borderless, translucent floating panel (notification/AirDrop-alert style).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make<V: View>(_ root: V) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .alertPanel

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedMask(radius: 18)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        let size = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 360), height: size.height))
        return panel
    }

    func placeTopRight(index: Int = 0) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.maxX - frame.width - 14, y: vf.maxY - frame.height - 12 - CGFloat(index) * (frame.height + 10))
        setFrameOrigin(origin)
    }
}

extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

@MainActor
final class PromptCenter {
    private var panels: [String: FloatingPanel] = [:]
    private var continuations: [String: CheckedContinuation<IncomingDecision, Never>] = [:]

    func ask(_ state: IncomingState, model: AppModel) async -> IncomingDecision {
        await withCheckedContinuation { cont in
            continuations[state.id] = cont
            present(state, model: model)
            // Decline automatically if ignored, like AirDrop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                self?.resolve(state, .decline)
            }
        }
    }

    func showIncoming(_ state: IncomingState, model: AppModel) { present(state, model: model) }

    private func present(_ state: IncomingState, model: AppModel) {
        let view = IncomingPromptView(state: state,
                                      onAccept: { [weak self] in self?.resolve(state, .accept) },
                                      onDecline: { [weak self] in self?.resolve(state, .decline) },
                                      onClose: { [weak self] in self?.close(state.id) })
        let panel = FloatingPanel.make(view)
        panel.placeTopRight(index: panels.count)
        panels[state.id] = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func resolve(_ state: IncomingState, _ decision: IncomingDecision) {
        guard let cont = continuations.removeValue(forKey: state.id) else { return }
        if decision == .decline { close(state.id) } else { state.phase = .receiving }
        cont.resume(returning: decision)
    }

    func finishIncoming(_ state: IncomingState) {
        let id = state.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (state.phase == .failed ? 8 : 6)) { [weak self] in
            self?.close(id)
        }
    }

    func close(_ id: String) {
        guard let p = panels.removeValue(forKey: id) else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    func showMessage(_ text: String, from sender: String) {
        let id = UUID().uuidString
        let view = MessagePromptView(text: text, sender: sender) { [weak self] in self?.close(id) }
        let panel = FloatingPanel.make(view)
        panel.placeTopRight(index: panels.count)
        panels[id] = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

// MARK: - Views

struct IncomingPromptView: View {
    @ObservedObject var state: IncomingState
    var onAccept: () -> Void
    var onDecline: () -> Void
    var onClose: () -> Void

    private var offer: IncomingOffer { state.offer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                DeviceAvatar(alias: offer.senderAlias, deviceType: offer.senderType, deviceModel: offer.senderModel,
                             phase: state.phase == .receiving ? .sending : .idle, progress: state.progress, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SwiftDrop").font(.system(size: 13, weight: .semibold))
                    Text(body1).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    if state.phase != .asking {
                        Text(body2).font(.system(size: 11)).foregroundStyle(state.phase == .failed ? .red : .secondary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 4)
                thumbnail
            }
            buttons
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 356)
        .animation(.snappy(duration: 0.25), value: state.phase)
    }

    @ViewBuilder private var buttons: some View {
        switch state.phase {
        case .asking:
            HStack(spacing: 8) {
                Button(action: onDecline) { Text("Decline").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Menu {
                    Button("Accept", action: onAccept)
                    Button("Always Accept from “\(offer.senderAlias)”") { state.alwaysAccept = true; onAccept() }
                } label: { Text("Accept") } primaryAction: { onAccept() }
                .menuStyle(.button)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .focusEffectDisabled()
        case .receiving:
            EmptyView()
        case .done:
            HStack(spacing: 8) {
                Button(action: onClose) { Text("Close").frame(maxWidth: .infinity) }
                    .focusEffectDisabled()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(state.files); onClose()
                } label: { Text("Show in Finder").frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        case .failed:
            Button(action: onClose) { Text("Close").frame(maxWidth: .infinity) }.controlSize(.large)
        }
    }

    private var body1: String {
        switch state.phase {
        case .asking: return "“\(offer.senderAlias)” would like to share \(noun)."
        case .receiving: return "Receiving \(noun) from “\(offer.senderAlias)”"
        case .done: return "Received \(noun) from “\(offer.senderAlias)”"
        case .failed: return "Couldn’t receive \(noun) from “\(offer.senderAlias)”"
        }
    }

    private var body2: String {
        switch state.phase {
        case .receiving:
            let got = Int64(Double(offer.totalBytes) * state.progress)
            return "\(got.byteString) of \(offer.totalBytes.byteString)"
        case .done: return "Saved to \(AppModel.shared.saveDirectory.lastPathComponent)"
        case .failed: return state.error ?? "Transfer failed"
        default: return ""
        }
    }

    /// "a photo", "3 photos", "a document", "“name.zip”"
    private var noun: String {
        let n = offer.files.count
        let images = offer.files.allSatisfy { $0.mimeType.hasPrefix("image/") }
        let videos = offer.files.allSatisfy { $0.mimeType.hasPrefix("video/") }
        if n == 1 {
            if images { return "a photo" }
            if videos { return "a video" }
            return "“\(offer.files[0].name.split(separator: "/").last.map(String.init) ?? offer.files[0].name)”"
        }
        if images { return "\(n) photos" }
        if videos { return "\(n) videos" }
        return "\(n) items"
    }

    private var thumbnail: some View {
        let first = offer.files.first
        let type = first.flatMap { UTType(mimeType: $0.mimeType) }
            ?? first.flatMap { UTType(filenameExtension: ($0.name as NSString).pathExtension) } ?? .data
        return Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable().frame(width: 40, height: 40)
            .overlay(alignment: .topTrailing) {
                if offer.files.count > 1 {
                    Text("\(offer.files.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.airDropBlue)).offset(x: 5, y: -3)
                }
            }
    }
}

struct MessagePromptView: View {
    let text: String
    let sender: String
    var onClose: () -> Void

    private var link: URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let s = u.scheme, ["http", "https"].contains(s.lowercased()) else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Message from “\(sender)”", systemImage: "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(text).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                if let link {
                    Button("Open") { NSWorkspace.shared.open(link); onClose() }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onClose()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
