import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Share sheet ▸ SwiftDrop. Runs its own discovery + LocalSend client so it
/// works even when the SwiftDrop app isn't running.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareSheet(model: model, done: { [weak self] in
            self?.model.stop()
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: { [weak self] in
            self?.model.cancelAll()
            self?.model.stop()
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.load((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
        model.start()
    }
}

@MainActor
final class ShareModel: ObservableObject, TransportHost {
    @Published var peers: [Peer] = []
    @Published var phases: [String: (TransferPhase, Double)] = [:]
    @Published var payload = OutgoingPayload()
    @Published var thumbnail: UIImage?
    @Published var loaded = false
    private var transport: LocalSendTransport?
    private var tasks: [String: Task<Void, Never>] = [:]

    let deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
    let receiveMode: ReceiveMode = .off   // the share sheet only sends
    var saveDirectory: URL { FileManager.default.temporaryDirectory }

    func start() {
        // Same identity and port as the SwiftDrop app (shared Keychain group), send-only.
        let cfg = LocalSendConfig(port: LocalSendConstants.port,
                                  deviceModel: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                                  deviceType: "mobile", tls: TLSIdentityStore.loadOrCreate(), advertise: false, serve: false)
        let t = LocalSendTransport(config: cfg)
        transport = t
        t.start(host: self)
        t.refresh(deep: true)
    }

    func stop() { transport?.stop() }

    func load(_ items: [NSExtensionItem]) {
        let providers = items.flatMap { $0.attachments ?? [] }
        Task {
            var files: [URL] = []
            var texts: [String] = []
            for p in providers {
                if let url = await Self.fileURL(from: p) { files.append(url) }
                else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                        let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(u.absoluteString)
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(s)
                }
            }
            payload = OutgoingPayload(fileURLs: files, texts: texts)
            loaded = true
            if let f = files.first, let img = UIImage(contentsOfFile: f.path) {
                thumbnail = img.preparingThumbnail(of: CGSize(width: 160, height: 160))
            }
        }
    }

    /// Copies whatever the host app shares (photo, video, document, folder) into our own temp space.
    private static func fileURL(from p: NSItemProvider) async -> URL? {
        let candidates = p.registeredTypeIdentifiers.compactMap(UTType.init)
            .filter { $0.conforms(to: .data) || $0.conforms(to: .directory) || $0 == .fileURL }
        guard let type = candidates.first(where: { $0 != .plainText && $0 != .url }) ?? candidates.first,
              !(type.conforms(to: .plainText) && candidates.count == 1) else { return nil }
        let suggested = p.suggestedName
        return await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let name = suggested.map { n in
                    (n as NSString).pathExtension.isEmpty ? n + "." + (type.preferredFilenameExtension ?? "dat") : n
                } ?? url.lastPathComponent
                let dest = AppPaths.newStageFile(named: name)
                cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
    }

    func send(to peer: Peer) {
        guard let transport, !payload.isEmpty, phases[peer.id]?.0.isActive != true else { return }
        phases[peer.id] = (.waiting, 0)
        let payload = self.payload
        tasks[peer.id] = Task { [weak self] in
            do {
                try await transport.send(payload, to: peer) { phase, p in
                    Task { @MainActor in
                        if self?.phases[peer.id]?.0.isTerminal != true { self?.phases[peer.id] = (phase, p) }
                    }
                }
                self?.phases[peer.id] = (.done, 1)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch let e as TransferError {
                self?.phases[peer.id] = (e.isDeclined ? .declined : .failed, 0)
            } catch { self?.phases[peer.id] = (.failed, 0) }
        }
    }

    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    // MARK: TransportHost (send-only)
    func isDiscoverable(by peerID: String?) -> Bool { false }
    func canReceive(from peerID: String) -> Bool { false }
    func transportDidUpdate(_ peer: Peer) {
        if let i = peers.firstIndex(where: { $0.id == peer.id }) { peers[i] = peer }
        else { withAnimation(.spring(duration: 0.35)) { peers.append(peer) } }
    }
    func transportDidLose(_ peerID: String) {}
    func transportShouldAccept(_ offer: IncomingOffer) async -> IncomingDecision { .decline }
    func transportDidReceiveMessage(_ text: String, offer: IncomingOffer) {}
    func transportIncomingProgress(_ offerID: String, received: Int64, total: Int64) {}
    func transportIncomingFinished(_ offerID: String, files: [URL], error: String?) {}
    func transportDidFail(_ message: String) {}
}

extension TransferError {
    var isDeclined: Bool { if case .declined = self { return true }; return false }
}

/// iOS AirDrop share sheet look: title bar with Done, item header, big round people.
struct ShareSheet: View {
    @ObservedObject var model: ShareModel
    let done: () -> Void
    let cancel: () -> Void

    private var anySent: Bool { model.phases.values.contains { $0.0 == .done } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Group {
                        if let t = model.thumbnail { Image(uiImage: t).resizable().scaledToFill() }
                        else { Image(systemName: model.payload.fileURLs.isEmpty ? "text.alignleft" : "doc.fill")
                                .font(.title2).foregroundStyle(.secondary) }
                    }
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.loaded ? model.payload.summary : "Preparing…").font(.headline).lineLimit(1)
                        Text("Choose a person to share with").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                if model.peers.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        RadarView(size: 130)
                        Text("Looking for people nearby…").font(.subheadline.weight(.medium))
                        Text("They need SwiftDrop or LocalSend on the same Wi‑Fi.").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 18) {
                            ForEach(model.peers) { p in
                                let ph = model.phases[p.id]
                                DeviceTile(alias: p.alias, deviceType: p.deviceType, deviceModel: p.deviceModel,
                                           phase: ph?.0 ?? .idle, progress: ph?.1 ?? 0, size: 72) {
                                    model.send(to: p)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("SwiftDrop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(anySent ? "Done" : "Cancel") { anySent ? done() : cancel() }.fontWeight(.semibold)
                }
            }
        }
    }
}
