import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers
import UserNotifications

/// iOS app state. iOS only lets a third-party app listen for transfers while it
/// is in the foreground (plus a short grace period when a transfer is running).
@MainActor
final class PhoneModel: ObservableObject, TransportHost {
    static let shared = PhoneModel()

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var transfers: [String: OutgoingTransfer] = [:]
    @Published private(set) var history: [HistoryItem] = []
    @Published var favorites: [Favorite] { didSet { save(favorites, "favorites") } }
    @Published var incoming: IncomingState?
    @Published var message: (text: String, sender: String)?
    @Published var statusMessage: String?
    @Published var receiveMode: ReceiveMode {
        didSet { UserDefaults.standard.set(receiveMode.rawValue, forKey: "receiveMode"); transport?.refresh(deep: false) }
    }
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName"); transport?.setAlias(deviceName) }
    }

    private var transport: LocalSendTransport?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var promptContinuation: CheckedContinuation<IncomingDecision, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var wasBackgrounded = false
    /// Senders whose "Tap to receive" notification was tapped: accept their next offer.
    private var consent: [String: Date] = [:]
    private let notifications = NotificationHandler()

    private init() {
        let d = UserDefaults.standard
        receiveMode = ReceiveMode(rawValue: d.string(forKey: "receiveMode") ?? "") ?? .everyone
        deviceName = d.string(forKey: "deviceName") ?? UIDevice.current.name
        favorites = Self.load("favorites") ?? []
        history = Self.load("history") ?? []
    }

    var saveDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir
    }

    // MARK: Lifecycle

    func start() {
        guard transport == nil else { return }
        let port = UInt16(UserDefaults.standard.integer(forKey: "SwiftDropPort"))
        let idiom = UIDevice.current.userInterfaceIdiom
        let cfg = LocalSendConfig(port: port == 0 ? LocalSendConstants.port : port,
                                  deviceModel: idiom == .pad ? "iPad" : "iPhone",
                                  deviceType: "mobile",
                                  tls: TLSIdentityStore.loadOrCreate(), wakeable: true)
        let t = LocalSendTransport(config: cfg)
        t.onWake = { [weak self] knock in Task { @MainActor in self?.knocked(knock) } }
        transport = t
        notifications.onTap = { [weak self] fp in Task { @MainActor in self?.consent[fp] = Date().addingTimeInterval(120) } }
        UNUserNotificationCenter.current().delegate = notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        SDLog.log("launched (\(UIApplication.shared.applicationState == .background ? "in background" : "foreground"))")
        t.start(host: self)
        // No scan here: a background relaunch (Bluetooth knock) should stay cheap. Discovery
        // runs when the app comes on screen (didBecomeActive).
        #if DEBUG
        // UI-test hook: -SwiftDropTestSend "swiftdrop://send?to=…"
        if let u = UserDefaults.standard.string(forKey: "SwiftDropTestSend"), let url = URL(string: u) { handle(url) }
        // Test cleanup: -SwiftDropTestDelete "Documents/a.bin|Library/TestOut" — only inside this app's container.
        if let list = UserDefaults.standard.string(forKey: "SwiftDropTestDelete") {
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
            for rel in list.split(separator: "|").map(String.init) where !rel.contains("..") {
                let target = home.appendingPathComponent(rel).standardizedFileURL
                guard target.path.hasPrefix(home.path + "/Documents/") || target.path.hasPrefix(home.path + "/Library/TestOut") else { continue }
                try? FileManager.default.removeItem(at: target)
            }
        }
        #endif
    }

    func refresh(deep: Bool = false) {
        browsingUntil = Date().addingTimeInterval(120)
        transport?.refresh(deep: deep)
    }

    func didBecomeActive() {
        if wasBackgrounded { wasBackgrounded = false; transport?.resumeAfterBackground() } else { refresh() }
    }

    /// A Mac, PC or phone knocked over Bluetooth while we were paused (or not running).
    private func knocked(_ k: BLEWake) {
        guard canReceive(from: k.f) else { return }
        if UIApplication.shared.applicationState == .active { refresh(); return }   // already listening
        notify(id: "knock-\(k.f)", body: "“\(k.a)” wants to send \(k.n). Tap to receive.", fingerprint: k.f)
    }

    /// Lock-screen notification (standard "active" level: shown on the Lock Screen and
    /// Notification Centre with a sound, as long as SwiftDrop's notifications are allowed).
    private func notify(id: String, body: String, fingerprint: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "SwiftDrop"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "swiftdrop"
        if let fingerprint { content.userInfo = ["fp": fingerprint] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private var inBackground: Bool { UIApplication.shared.applicationState != .active }

    func didEnterBackground() {
        wasBackgrounded = true
        let busy = incoming?.phase == .receiving || transfers.values.contains { $0.phase.isActive }
        guard busy, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SwiftDrop transfer") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    // MARK: TransportHost

    func isFavorite(_ id: String?) -> Bool { id.map { fid in favorites.contains { $0.id == fid } } ?? false }

    /// Set while a sending screen is open, so devices we're sending to can see us.
    private var browsingUntil = Date.distantPast

    func isDiscoverable(by peerID: String?) -> Bool {
        if Date() < browsingUntil { return true }
        switch receiveMode {
        case .everyone: return true
        // Keep advertising (Bluetooth) so favourites can find and wake us; only favourites get answers.
        case .favorites: return peerID == nil || isFavorite(peerID)
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
        if let i = peers.firstIndex(where: { $0.id == peer.id }) { peers[i] = peer }
        else { withAnimation(.spring(duration: 0.35)) { peers.append(peer) } }
        rememberPeers()
    }

    func transportDidLose(_ peerID: String) {
        guard transfer(for: peerID)?.phase.isActive != true else { return }
        withAnimation { peers.removeAll { $0.id == peerID } }
    }

    func transportShouldAccept(_ offer: IncomingOffer) async -> IncomingDecision {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["knock-\(offer.senderID)"])
        if let until = consent.removeValue(forKey: offer.senderID), until > Date() {   // they tapped "Tap to receive"
            let state = IncomingState(offer: offer)
            state.phase = .receiving
            incoming = state
            return .accept
        }
        let state = IncomingState(offer: offer)
        if favorites.first(where: { $0.id == offer.senderID })?.autoAccept == true {
            state.phase = .receiving
            incoming = state
            return .accept
        }
        if promptContinuation != nil { return .decline }
        incoming = state
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let decision: IncomingDecision = await withCheckedContinuation { cont in
            promptContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.respond(.decline) }
        }
        if decision == .accept {
            state.phase = .receiving
            if state.alwaysAccept {
                favorites.removeAll { $0.id == offer.senderID }
                favorites.append(Favorite(id: offer.senderID, alias: offer.senderAlias, autoAccept: true))
            }
        } else {
            incoming = nil
        }
        return decision
    }

    func respond(_ d: IncomingDecision) {
        guard let c = promptContinuation else { return }
        promptContinuation = nil
        c.resume(returning: d)
    }

    func transportDidReceiveMessage(_ text: String, offer: IncomingOffer) {
        message = (text, offer.senderAlias)
        if inBackground { notify(id: "msg-\(offer.id)", body: "Message from “\(offer.senderAlias)”: \(text.prefix(140))") }
        addHistory(HistoryItem(direction: .received, title: String(text.prefix(80)), deviceAlias: offer.senderAlias,
                               paths: [], text: text))
    }

    func transportIncomingProgress(_ offerID: String, received: Int64, total: Int64) {
        guard let s = incoming, s.id == offerID else { return }
        s.progress = total > 0 ? Double(received) / Double(total) : 0
    }

    func transportIncomingFinished(_ offerID: String, files: [URL], error: String?) {
        defer { endBackgroundTask() }
        guard let s = incoming, s.id == offerID else { return }
        if let error {
            s.phase = .failed; s.error = error
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        s.files = files
        s.progress = 1
        s.phase = .done
        if inBackground {
            notify(id: "done-\(offerID)", body: "Received \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) items") from “\(s.offer.senderAlias)”.")
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        addHistory(HistoryItem(direction: .received,
                               title: files.count == 1 ? files[0].lastPathComponent : "\(s.offer.files.count) Items",
                               deviceAlias: s.offer.senderAlias, paths: files.map(\.path)))
        Task { await saveMediaToPhotos(files) }
    }

    func transportDidFail(_ message: String) { statusMessage = message }

    /// Like AirDrop: photos and videos land in the Photos library.
    private func saveMediaToPhotos(_ urls: [URL]) async {
        let media = urls.filter {
            guard let t = UTType(filenameExtension: $0.pathExtension) else { return false }
            return t.conforms(to: .image) || t.conforms(to: .movie)
        }
        guard !media.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        for url in media {
            let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
                }
                try? FileManager.default.removeItem(at: url)
            } catch { continue }
        }
    }

    // MARK: Sending

    func transfer(for peerID: String) -> OutgoingTransfer? {
        transfers.values.filter { $0.peerID == peerID }.max { $0.started < $1.started }
    }

    func send(_ payload: OutgoingPayload, to peerID: String) {
        guard !payload.isEmpty, let peer = peers.first(where: { $0.id == peerID }), let transport else { return }
        if transfer(for: peerID)?.phase.isActive == true { return }
        let id = UUID().uuidString
        transfers[id] = OutgoingTransfer(id: id, peerID: peerID, phase: .waiting, progress: 0, title: payload.summary)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tasks[id] = Task { [weak self] in
            var final: TransferPhase = .done
            var msg: String?
            do {
                try await transport.send(payload, to: peer) { phase, p in
                    Task { @MainActor in self?.update(id, phase, p) }
                }
            } catch let e as TransferError {
                final = e.isDeclined ? .declined : (e.isCancelled ? .cancelled : .failed); msg = e.localizedDescription
            } catch { final = .failed; msg = error.localizedDescription }
            self?.finish(id, final, msg, payload: payload, peer: peer)
        }
    }

    func cancel(peerID: String) {
        if let t = transfer(for: peerID), t.phase.isActive { tasks[t.id]?.cancel() }
    }

    private func update(_ id: String, _ phase: TransferPhase, _ p: Double) {
        guard var t = transfers[id], !t.phase.isTerminal else { return }
        t.phase = phase; t.progress = p
        transfers[id] = t
    }

    private func finish(_ id: String, _ phase: TransferPhase, _ msg: String?, payload: OutgoingPayload, peer: Peer) {
        guard var t = transfers[id] else { return }
        if phase != .done { NSLog("SwiftDrop: send to \(peer.alias) ended \(phase.rawValue): \(msg ?? "")") }
        t.phase = phase; t.message = msg
        if phase == .done {
            t.progress = 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            addHistory(HistoryItem(direction: .sent, title: payload.summary, deviceAlias: peer.alias,
                                   paths: payload.fileURLs.map(\.path), text: payload.texts.first))
        }
        transfers[id] = t
        tasks[id] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.transfers[id]?.phase.isTerminal == true { self?.transfers[id] = nil }
        }
    }

    /// Automation hook for Shortcuts:
    ///   swiftdrop://send?to=<device name or id>&text=<message>&file=<path>&file=<path>
    /// Waits up to 30 s for the device to be discovered.
    func handle(_ url: URL) {
        guard url.scheme == "swiftdrop", url.host == "send",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let to = items.first(where: { $0.name == "to" })?.value else { return }
        // Relative paths are inside SwiftDrop's own container (e.g. "Documents/x.pdf").
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let payload = OutgoingPayload(fileURLs: items.filter { $0.name == "file" }.compactMap { $0.value }
                                        .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : home.appendingPathComponent($0) },
                                      texts: items.filter { $0.name == "text" }.compactMap(\.value))
        refresh(deep: false)
        Task {
            for i in 0..<120 {
                if let p = peers.first(where: { $0.id == to || $0.alias.localizedCaseInsensitiveCompare(to) == .orderedSame }) {
                    NSLog("SwiftDrop: found \(p.alias) after \(i * 250) ms (LAN: \(p.hasLAN), direct: \(p.awdlService != nil))")
                    send(payload, to: p.id); return
                }
                if i % 20 == 19 { refresh(deep: false) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            statusMessage = "“\(to)” isn’t nearby"
        }
    }

    func toggleFavorite(_ peer: Peer) {
        if isFavorite(peer.id) { favorites.removeAll { $0.id == peer.id } }
        else { favorites.append(Favorite(id: peer.id, alias: peer.alias, autoAccept: false)) }
    }

    // MARK: Persistence

    private func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        save(history, "history")
    }

    func clearHistory() { history.removeAll(); save(history, "history") }

    private func rememberPeers() {
        let hosts = peers.map { ["host": $0.host, "port": "\($0.port)", "scheme": $0.scheme] }
        UserDefaults.standard.set(hosts, forKey: "knownHosts")
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

extension TransferError {
    var isDeclined: Bool { if case .declined = self { return true }; return false }
    var isCancelled: Bool { if case .cancelled = self { return true }; return false }
}

/// Taps on "Tap to receive" notifications.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onTap: ((String) -> Void)?
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let fp = r.notification.request.content.userInfo["fp"] as? String { onTap?(fp) }
        done()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([]) }
}
