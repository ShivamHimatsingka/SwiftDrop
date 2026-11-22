import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject, TransportHost {
    static let shared = AppModel()

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var transfers: [String: OutgoingTransfer] = [:]
    @Published private(set) var history: [HistoryItem] = []
    @Published var favorites: [Favorite] { didSet { saveFavorites() } }
    @Published var pendingPayload: OutgoingPayload?
    @Published var incoming: IncomingState?
    @Published var statusMessage: String?

    @Published var receiveMode: ReceiveMode {
        didSet {
            UserDefaults.standard.set(receiveMode.rawValue, forKey: Keys.mode)
            transports.forEach { $0.refresh(deep: false) }   // applies visibility immediately
        }
    }
    /// The main switch (Control Center style). Restores the last "on" mode.
    var receivingEnabled: Bool {
        get { receiveMode != .off }
        set {
            if newValue {
                let last = ReceiveMode(rawValue: UserDefaults.standard.string(forKey: "lastOnMode") ?? "") ?? .everyone
                receiveMode = last == .off ? .everyone : last
            } else {
                UserDefaults.standard.set(receiveMode.rawValue, forKey: "lastOnMode")
                receiveMode = .off
            }
        }
    }
    @Published var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: Keys.name)
            transports.forEach { $0.setAlias(deviceName) }
        }
    }
    @Published var useEncryption: Bool {
        didSet { UserDefaults.standard.set(useEncryption, forKey: Keys.tls); restartTransports() }
    }
    @Published var saveDirectoryPath: String {
        didSet { UserDefaults.standard.set(saveDirectoryPath, forKey: Keys.saveDir) }
    }
    @Published var directLink: DirectLinkPreference = .current {
        didSet { UserDefaults.standard.set(directLink.rawValue, forKey: "directLink"); restartTransports() }
    }
    @Published var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Keys.sounds) }
    }

    private(set) var transports: [NearbyTransport] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var sendingUIActiveUntil = Date.distantPast
    let prompts = PromptCenter()

    private enum Keys {
        static let mode = "receiveMode", name = "deviceName", favs = "favorites", tls = "useEncryption"
        static let saveDir = "saveDirectory", sounds = "playSounds"
    }

    private init() {
        let d = UserDefaults.standard
        receiveMode = ReceiveMode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .everyone
        deviceName = d.string(forKey: Keys.name) ?? Host.current().localizedName ?? "Mac"
        useEncryption = d.object(forKey: Keys.tls) as? Bool ?? true
        saveDirectoryPath = d.string(forKey: Keys.saveDir) ?? AppPaths.downloads.path
        playSounds = d.object(forKey: Keys.sounds) as? Bool ?? true
        favorites = (d.data(forKey: Keys.favs)).flatMap { try? JSONDecoder().decode([Favorite].self, from: $0) } ?? []
        history = Self.loadHistory()
    }

    // MARK: Lifecycle

    func start() {
        let tls = useEncryption ? TLSIdentityStore.loadOrCreate() : nil
        let cfg = LocalSendConfig(deviceModel: MacModel.name, deviceType: "desktop", tls: tls)
        var list: [NearbyTransport] = [LocalSendTransport(config: cfg)]
        if UserDefaults.standard.bool(forKey: "SwiftDropExperimentalQuickShare") { list.append(QuickShareTransport()) }
        transports = list
        transports.forEach { $0.start(host: self) }
    }

    private func restartTransports() {
        transports.forEach { $0.stop() }
        peers.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
    }

    var localSend: LocalSendTransport? { transports.compactMap { $0 as? LocalSendTransport }.first }

    /// Called whenever a sending surface (menu popover, share sheet) is visible.
    func sendingUIDidAppear(deep: Bool = false) {
        sendingUIActiveUntil = Date().addingTimeInterval(120)
        lastFullRefresh = Date()
        transports.forEach { $0.refresh(deep: deep || peers.isEmpty) }
    }

    private var lastFullRefresh = Date.distantPast
    private var lastCheck = Date.distantPast
    /// True while the menu-bar popover is on screen (drives the live status timer).
    var popoverVisible = false

    /// Called repeatedly while a sending UI stays open: a full refresh at most every 30 s,
    /// otherwise a cheap liveness check (online / Asleep / gone) every ~5 s.
    func sendingUIStillOpen() {
        if Date().timeIntervalSince(lastFullRefresh) > 30 { sendingUIDidAppear(); return }
        guard Date().timeIntervalSince(lastCheck) > 4 else { return }
        lastCheck = Date()
        localSend?.checkPeers()
    }

    // MARK: TransportHost

    var saveDirectory: URL { URL(fileURLWithPath: saveDirectoryPath, isDirectory: true) }

    func isFavorite(_ id: String?) -> Bool { id.map { fid in favorites.contains { $0.id == fid } } ?? false }

    func isDiscoverable(by peerID: String?) -> Bool {
        switch receiveMode {
        case .everyone: return true
        case .favorites: return isFavorite(peerID)
        case .off: return false
        }
    }

    func canReceive(from peerID: String) -> Bool {
        switch receiveMode {
        case .everyone: return true
        case .favorites: return isFavorite(peerID)
        case .off: return false
        }
    }

    func transportDidUpdate(_ peer: Peer) {
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            if peers[i] != peer { peers[i] = peer }
        } else {
            withAnimation(.spring(duration: 0.35)) { peers.append(peer) }
            peers.sort { (isFavorite($0.id) ? 0 : 1, $0.alias) < (isFavorite($1.id) ? 0 : 1, $1.alias) }
        }
        if let f = favorites.firstIndex(where: { $0.id == peer.id }), favorites[f].alias != peer.alias {
            favorites[f].alias = peer.alias
        }
    }

    func transportDidLose(_ peerID: String) {
        guard transfer(for: peerID)?.phase.isActive != true else { return }
        withAnimation { peers.removeAll { $0.id == peerID } }
    }

    func transportShouldAccept(_ offer: IncomingOffer) async -> IncomingDecision {
        if favorites.first(where: { $0.id == offer.senderID })?.autoAccept == true {
            let state = IncomingState(offer: offer)
            state.phase = .receiving
            incoming = state
            prompts.showIncoming(state, model: self)
            return .accept
        }
        let state = IncomingState(offer: offer)
        incoming = state
        let decision = await prompts.ask(state, model: self)
        if decision == .accept {
            state.phase = .receiving
            if state.alwaysAccept { setFavorite(id: offer.senderID, alias: offer.senderAlias, autoAccept: true) }
        } else {
            incoming = nil
        }
        return decision
    }

    func transportDidReceiveMessage(_ text: String, offer: IncomingOffer) {
        prompts.showMessage(text, from: offer.senderAlias)
        addHistory(HistoryItem(direction: .received, title: String(text.prefix(80)), deviceAlias: offer.senderAlias,
                               paths: [], text: text))
        if playSounds { NSSound(named: "Glass")?.play() }
    }

    func transportIncomingProgress(_ offerID: String, received: Int64, total: Int64) {
        guard let s = incoming, s.id == offerID else { return }
        s.progress = total > 0 ? Double(received) / Double(total) : 0
    }

    func transportIncomingFinished(_ offerID: String, files: [URL], error: String?) {
        if let error { SDLog.log("receive \(offerID.prefix(8)) failed: \(error)") }
        guard let s = incoming, s.id == offerID else { return }
        s.files = files
        if let error {
            s.phase = .failed
            s.error = error
            if playSounds { NSSound(named: "Basso")?.play() }
        } else {
            s.progress = 1
            s.phase = .done
            if playSounds { NSSound(named: "Glass")?.play() }
            let title = files.count == 1 ? files[0].lastPathComponent : "\(s.offer.files.count) Items"
            addHistory(HistoryItem(direction: .received, title: title, deviceAlias: s.offer.senderAlias,
                                   paths: files.map(\.path)))
        }
        prompts.finishIncoming(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.incoming === s { self?.incoming = nil }
        }
    }

    func transportDidFail(_ message: String) {
        statusMessage = message
    }

    // MARK: Sending

    func transfer(for peerID: String) -> OutgoingTransfer? {
        transfers.values.filter { $0.peerID == peerID }.max { $0.started < $1.started }
    }

    func transferStatus(_ id: String) -> OutgoingTransfer? { transfers[id] }

    @discardableResult
    func send(_ payload: OutgoingPayload, to peerID: String) -> String? {
        guard !payload.isEmpty, let peer = peers.first(where: { $0.id == peerID }),
              let transport = transports.first(where: { $0.id == peer.transportID }) else { return nil }
        if let active = transfer(for: peerID), active.phase.isActive { return active.id }

        let id = UUID().uuidString
        transfers[id] = OutgoingTransfer(id: id, peerID: peerID, phase: .waiting, progress: 0, title: payload.summary)
        let task = Task { [weak self] in
            do {
                try await transport.send(payload, to: peer) { phase, progress in
                    Task { @MainActor in self?.updateTransfer(id, phase: phase, progress: progress) }
                }
                self?.finishTransfer(id, phase: .done, message: nil, payload: payload, peer: peer)
            } catch let e as TransferError {
                switch e {
                case .declined: self?.finishTransfer(id, phase: .declined, message: e.localizedDescription)
                case .cancelled: self?.finishTransfer(id, phase: .cancelled, message: nil)
                default: self?.finishTransfer(id, phase: .failed, message: e.localizedDescription)
                }
            } catch is CancellationError {
                self?.finishTransfer(id, phase: .cancelled, message: nil)
            } catch {
                self?.finishTransfer(id, phase: .failed, message: error.localizedDescription)
            }
        }
        tasks[id] = task
        return id
    }

    func cancelTransfer(_ id: String) { tasks[id]?.cancel() }

    func cancelTransfer(forPeer peerID: String) {
        if let t = transfer(for: peerID), t.phase.isActive { cancelTransfer(t.id) }
    }

    private func updateTransfer(_ id: String, phase: TransferPhase, progress: Double) {
        guard var t = transfers[id], !t.phase.isTerminal else { return }
        t.phase = phase
        t.progress = progress
        transfers[id] = t
    }

    private func finishTransfer(_ id: String, phase: TransferPhase, message: String?,
                                payload: OutgoingPayload? = nil, peer: Peer? = nil) {
        guard var t = transfers[id] else { return }
        if phase != .done { SDLog.log("transfer to \(peer?.alias ?? t.peerID) ended \(phase.rawValue): \(message ?? "-")") }
        t.phase = phase
        t.message = message
        if phase == .done { t.progress = 1 }
        transfers[id] = t
        tasks[id] = nil
        if phase == .done, let payload, let peer {
            addHistory(HistoryItem(direction: .sent, title: payload.summary, deviceAlias: peer.alias,
                                   paths: payload.fileURLs.map(\.path), text: payload.texts.first))
        }
        // Return the avatar to idle after a moment, like AirDrop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.transfers[id]?.phase.isTerminal == true { self?.transfers[id] = nil }
        }
    }

    // MARK: Clipboard

    func clipboardPayload() -> OutgoingPayload? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return OutgoingPayload(fileURLs: urls)
        }
        if let image = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff]) != nil,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let f = AppPaths.newStageFile(named: "Clipboard \(Self.stamp()).png")
            if (try? png.write(to: f)) != nil { return OutgoingPayload(fileURLs: [f]) }
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            return OutgoingPayload(texts: [s])
        }
        return nil
    }

    func clipboardSummary() -> (symbol: String, text: String)? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ("doc.on.doc", urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        }
        if pb.availableType(from: [.png, .tiff]) != nil { return ("photo", "Image") }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return ("text.alignleft", String(s.prefix(60)).replacingOccurrences(of: "\n", with: " "))
        }
        return nil
    }

    func sendClipboard(to peerID: String) {
        guard let payload = clipboardPayload() else { NSSound.beep(); return }
        send(payload, to: peerID)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; return f.string(from: Date())
    }

    // MARK: Favorites

    func setFavorite(id: String, alias: String, autoAccept: Bool) {
        if let i = favorites.firstIndex(where: { $0.id == id }) { favorites[i].autoAccept = autoAccept }
        else { favorites.append(Favorite(id: id, alias: alias, autoAccept: autoAccept)) }
    }

    func toggleFavorite(_ peer: Peer) {
        if isFavorite(peer.id) { favorites.removeAll { $0.id == peer.id } }
        else { favorites.append(Favorite(id: peer.id, alias: peer.alias, autoAccept: false)) }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: Keys.favs)
    }

    // MARK: History

    nonisolated private static var historyURL: URL { AppPaths.support.appendingPathComponent("history.json") }

    private static func loadHistory() -> [HistoryItem] {
        (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([HistoryItem].self, from: $0) } ?? []
    }

    private func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        let snapshot = history
        DispatchQueue.global(qos: .utility).async {
            try? JSONEncoder().encode(snapshot).write(to: Self.historyURL, options: .atomic)
        }
    }

    func clearHistory() {
        history.removeAll()
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    func open(_ item: HistoryItem) {
        let existing = item.paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else if let text = item.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { statusMessage = "Login item: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }
}
