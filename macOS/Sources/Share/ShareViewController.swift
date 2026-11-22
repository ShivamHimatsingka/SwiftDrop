import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Finder ▸ Share ▸ SwiftDrop. Shows an AirDrop-style device picker; the
/// running menu bar app performs discovery and the actual transfer.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let state = ShareState()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 290))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: ShareView(state: state,
                                                        onDone: { [weak self] in self?.finish() },
                                                        onCancel: { [weak self] in self?.cancel() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        view = effect
        preferredContentSize = NSSize(width: 480, height: 290)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        state.load(items)
        state.startPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        state.stopPolling()
    }

    private func finish() {
        state.stopPolling()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancel() {
        state.stopPolling()
        state.cancelActive()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

// MARK: - State

private final class CollectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, ShareItem)] = []
    func add(_ i: Int, _ item: ShareItem) { lock.lock(); items.append((i, item)); lock.unlock() }
    var sorted: [ShareItem] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.0 < $1.0 }.map(\.1) }
}

enum ShareItem: @unchecked Sendable {
    case file(URL)
    case text(String)
    case data(Data, name: String)
}

@MainActor
final class ShareState: ObservableObject {
    @Published var items: [ShareItem] = []
    @Published var devices: [ControlDevice] = []
    @Published var phases: [String: (phase: TransferPhase, progress: Double, message: String?)] = [:]
    @Published var appReachable = true
    @Published var loading = true
    @Published var thumbnail: NSImage?

    private var pollTimer: Timer?
    private var transferIDs: [String: String] = [:]   // deviceId -> transferId
    private var launchedApp = false
    private var ticks = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        return URLSession(configuration: c)
    }()

    var anySent: Bool { phases.values.contains { $0.phase == .done } }
    var anyActive: Bool { phases.values.contains { $0.phase.isActive } }

    // MARK: Loading shared items

    func load(_ extensionItems: [NSExtensionItem]) {
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        Self.collect(providers) { [weak self] items in
            Task { @MainActor in
                self?.items = items
                self?.makeThumbnail()
            }
        }
    }

    nonisolated private static func collect(_ providers: [NSItemProvider], done: @escaping @Sendable ([ShareItem]) -> Void) {
        let group = DispatchGroup()
        let box = CollectBox()
        let add: @Sendable (Int, ShareItem) -> Void = { i, item in box.add(i, item) }

        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { obj, _ in
                    if let url = obj as? URL { add(i, .file(url)) }
                    else if let d = obj as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) { add(i, .file(url)) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier) { obj, _ in
                    if let url = obj as? URL { add(i, url.isFileURL ? .file(url) : .text(url.absoluteString)) }
                    else if let d = obj as? Data, let s = String(data: d, encoding: .utf8) { add(i, .text(s)) }
                    group.leave()
                }
            } else if let imageType = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                p.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                    if let data {
                        let ext = UTType(imageType)?.preferredFilenameExtension ?? "png"
                        add(i, .data(data, name: "Image.\(ext)"))
                    }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                p.loadItem(forTypeIdentifier: UTType.plainText.identifier) { obj, _ in
                    if let s = obj as? String { add(i, .text(s)) }
                    else if let a = obj as? NSAttributedString { add(i, .text(a.string)) }
                    else if let d = obj as? Data, let s = String(data: d, encoding: .utf8) { add(i, .text(s)) }
                    group.leave()
                }
            } else if let t = p.registeredTypeIdentifiers.first {
                p.loadDataRepresentation(forTypeIdentifier: t) { data, _ in
                    if let data {
                        let ext = UTType(t)?.preferredFilenameExtension ?? "dat"
                        add(i, .data(data, name: "Item.\(ext)"))
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { done(box.sorted) }
    }

    /// Real QuickLook thumbnail of the first item, like AirDrop.
    private func makeThumbnail() {
        guard let first = items.first else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: 88, height: 88)
        switch first {
        case .file(let url):
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let img = rep?.nsImage else { return }
                Task { @MainActor in self?.thumbnail = img }
            }
        case .data(let d, _):
            thumbnail = NSImage(data: d)
        case .text:
            break
        }
    }

    var title: String {
        if items.count == 1 {
            switch items[0] {
            case .file(let u): return u.lastPathComponent
            case .text(let s): return "“\(s.prefix(40))”"
            case .data(_, let n): return n
            }
        }
        return items.isEmpty ? "Preparing…" : "\(items.count) Items"
    }

    var subtitle: String {
        var bytes: Int64 = 0
        var folders = 0
        for item in items {
            switch item {
            case .file(let u):
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if v?.isDirectory == true { folders += 1 } else { bytes += Int64(v?.fileSize ?? 0) }
            case .text(let s): bytes += Int64(s.utf8.count)
            case .data(let d, _): bytes += Int64(d.count)
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s") · \(size)" : size
    }

    var icon: NSImage {
        if items.count == 1, case .file(let u) = items[0] { return NSWorkspace.shared.icon(forFile: u.path) }
        if items.allSatisfy({ if case .text = $0 { return true }; return false }), !items.isEmpty {
            return NSWorkspace.shared.icon(for: .plainText)
        }
        if items.count == 1, case .data = items[0] { return NSWorkspace.shared.icon(for: .image) }
        return NSWorkspace.shared.icon(for: .folder)
    }

    // MARK: Polling the app

    func startPolling() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        ticks += 1
        if ticks % 3 == 1 || devices.isEmpty { fetchDevices() }
        for (deviceID, transferID) in transferIDs { fetchStatus(deviceID: deviceID, transferID: transferID) }
    }

    private func fetchDevices() {
        var comps = URLComponents(url: ControlAPI.baseURL.appendingPathComponent("devices"), resolvingAgainstBaseURL: false)!
        if ticks == 1 { comps.queryItems = [URLQueryItem(name: "deep", value: "0")] }
        session.dataTask(with: comps.url!) { [weak self] data, resp, err in
            let list = data.flatMap { try? JSONDecoder().decode([ControlDevice].self, from: $0) }
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    self.appReachable = true
                    self.loading = false
                    if list != self.devices { withAnimation(.spring(duration: 0.35)) { self.devices = list } }
                } else {
                    self.appReachable = false
                    self.launchAppIfNeeded()
                }
            }
        }.resume()
    }

    private func launchAppIfNeeded() {
        guard !launchedApp else { return }
        launchedApp = true
        // .../SwiftDrop.app/Contents/PlugIns/SwiftDropShare.appex
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if appURL.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, err in
                if err != nil, let u = URL(string: "\(ControlAPI.appURLScheme)://launch") {
                    DispatchQueue.main.async { NSWorkspace.shared.open(u) }
                }
            }
        } else if let u = URL(string: "\(ControlAPI.appURLScheme)://launch") {
            NSWorkspace.shared.open(u)
        }
    }

    private func fetchStatus(deviceID: String, transferID: String) {
        var comps = URLComponents(url: ControlAPI.baseURL.appendingPathComponent("transfer"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: transferID)]
        session.dataTask(with: comps.url!) { [weak self] data, _, _ in
            guard let data, let s = try? JSONDecoder().decode(ControlTransferStatus.self, from: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.phases[deviceID] = (s.phase, s.progress, s.message)
                if s.phase.isTerminal { self.transferIDs[deviceID] = nil }
            }
        }.resume()
    }

    // MARK: Sending

    func send(to device: ControlDevice) {
        guard !items.isEmpty, phases[device.id]?.phase.isActive != true else { return }
        phases[device.id] = (.waiting, 0, nil)
        let items = self.items
        Task {
            do {
                var paths: [String] = []
                var texts: [String] = []
                for item in items {
                    switch item {
                    case .file(let u): paths.append(u.path)
                    case .text(let s): texts.append(s)
                    case .data(let d, let name): paths.append(try await stage(d, name: name))
                    }
                }
                let body = try JSONEncoder().encode(ControlSendRequest(deviceId: device.id, paths: paths, texts: texts))
                var req = URLRequest(url: ControlAPI.baseURL.appendingPathComponent("send"))
                req.httpMethod = "POST"
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (data, _) = try await session.data(for: req)
                let r = try JSONDecoder().decode(ControlSendResponse.self, from: data)
                transferIDs[device.id] = r.transferId
            } catch {
                phases[device.id] = (.failed, 0, error.localizedDescription)
            }
        }
    }

    private func stage(_ data: Data, name: String) async throws -> String {
        var comps = URLComponents(url: ControlAPI.baseURL.appendingPathComponent("stage"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 60)
        req.httpMethod = "POST"
        let (resp, _) = try await session.upload(for: req, from: data)
        return try JSONDecoder().decode(ControlStageResponse.self, from: resp).path
    }

    func cancelActive() {
        for (_, tid) in transferIDs {
            var comps = URLComponents(url: ControlAPI.baseURL.appendingPathComponent("cancel"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "id", value: tid)]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "POST"
            session.dataTask(with: req).resume()
        }
    }
}

// MARK: - View (AirDrop sheet)

struct ShareView: View {
    @ObservedObject var state: ShareState
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Item being shared
            HStack(spacing: 12) {
                Image(nsImage: state.thumbnail ?? state.icon)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: state.thumbnail == nil ? 0 : 5, style: .continuous))
                    .shadow(color: .black.opacity(state.thumbnail == nil ? 0 : 0.2), radius: 1.5, y: 0.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(state.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            Text("SwiftDrop")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            ZStack {
                if state.devices.isEmpty {
                    VStack(spacing: 4) {
                        RadarView(size: 92)
                        Text(state.appReachable ? "Looking for people nearby…" : "Starting SwiftDrop…")
                            .font(.system(size: 12, weight: .medium))
                        Text("People using LocalSend on the same Wi‑Fi will appear here.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(state.devices) { d in
                                let p = state.phases[d.id]
                                DeviceTile(alias: d.alias, deviceType: d.deviceType, deviceModel: d.deviceModel,
                                           phase: p?.phase ?? .idle, progress: p?.progress ?? 0,
                                           isFavorite: d.isFavorite, size: 64) {
                                    state.send(to: d)
                                }
                                .help(p?.message ?? d.alias)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minWidth: 480, alignment: .leading)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 158)
            .animation(.snappy(duration: 0.3), value: state.devices.map(\.id))

            HStack {
                Spacer()
                if state.anySent || state.anyActive {
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction).controlSize(.large)
                } else {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).controlSize(.large)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 4)
        }
        .frame(width: 480)
    }
}
