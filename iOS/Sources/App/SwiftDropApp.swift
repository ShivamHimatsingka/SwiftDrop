import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct SwiftDropApp: App {
    @StateObject private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase

    init() {
        // iOS closes our sockets while the app is paused; writing to one afterwards raises
        // SIGPIPE, which would kill the app on unlock. Treat it as a normal I/O error instead.
        signal(SIGPIPE, SIG_IGN)
        // Start immediately — not when a screen appears. iOS may relaunch SwiftDrop in the
        // background (no UI) to deliver a Bluetooth knock; the engine must be running for that.
        PhoneModel.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .onAppear { model.start() }
                .onOpenURL { model.handle($0) }
        }
        .onChange(of: phase) { _, p in
            SDLog.log("scene → \(p)")
            if p == .active { model.didBecomeActive() }
            if p == .background { model.didEnterBackground() }
        }
    }
}

/// Modelled on Settings ▸ General ▸ AirDrop plus the AirDrop people row.
struct HomeView: View {
    @ObservedObject var model: PhoneModel
    @State private var target: Peer?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        RadarView(size: 110, active: model.receiveMode != .off)
                        Text("SwiftDrop lets you share instantly with people nearby — Android, Windows, Linux and Macs.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(ReceiveMode.allCases) { mode in
                        Button { model.receiveMode = mode } label: {
                            HStack {
                                Text(mode.longTitle).foregroundStyle(.primary)
                                Spacer()
                                if model.receiveMode == mode {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.airDropBlue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .tint(.primary)
                    }
                } header: { Text("Allow me to be discovered by") } footer: {
                    Text("Keep SwiftDrop open to receive. iOS doesn’t let apps other than AirDrop listen in the background.")
                }

                Section {
                    if model.peers.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for people nearby…").foregroundStyle(.secondary)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(model.peers) { peer in
                                    let t = model.transfer(for: peer.id)
                                    DeviceTile(alias: peer.alias, deviceType: peer.deviceType, deviceModel: peer.deviceModel,
                                               phase: t?.phase ?? .idle, progress: t?.progress ?? 0,
                                               isFavorite: model.isFavorite(peer.id), size: 64) {
                                        target = peer
                                    }
                                    .contextMenu {
                                        Button(model.isFavorite(peer.id) ? "Remove from Favorites" : "Add to Favorites",
                                               systemImage: "star") { model.toggleFavorite(peer) }
                                        if t?.phase.isActive == true {
                                            Button("Stop Sending", systemImage: "xmark", role: .destructive) { model.cancel(peerID: peer.id) }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } header: {
                    HStack { Text("Nearby"); Spacer(); Button("Refresh") { model.refresh(deep: true) }.font(.caption) }
                } footer: {
                    if let msg = model.statusMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .onTapGesture { model.statusMessage = nil }
                    }
                }

                if !model.history.isEmpty {
                    Section {
                        ForEach(model.history.prefix(8)) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.title3).foregroundStyle(Color.airDropBlue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).lineLimit(1)
                                    Text("\(item.direction == .sent ? "To" : "From") \(item.deviceAlias) · \(item.date.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        HStack { Text("Recent"); Spacer(); Button("Clear") { model.clearHistory() }.font(.caption) }
                    }
                }

                Section {
                    TextField("Device name", text: $model.deviceName)
                    Picker("Direct Wi‑Fi link", selection: Binding(get: { DirectLinkPreference.current },
                                                                  set: { UserDefaults.standard.set($0.rawValue, forKey: "directLink") })) {
                        ForEach(DirectLinkPreference.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("This iPhone") } footer: {
                    Text("Direct Wi‑Fi link connects straight to nearby Macs and iPhones, like AirDrop, without leaving your network. Bluetooth helps find devices.")
                }
            }
            .navigationTitle("SwiftDrop")
            .refreshable { model.refresh(deep: true) }
            .confirmationDialog("Send to \(target?.alias ?? "")", isPresented: Binding(get: { target != nil && !showPhotos && !showFiles },
                                                                                set: { if !$0 && !showPhotos && !showFiles { target = nil } }),
                                titleVisibility: .visible) {
                Button("Photos & Videos") { showPhotos = true }
                Button("Files") { showFiles = true }
                if let s = UIPasteboard.general.string, let t = target {
                    Button("Clipboard Text") { model.send(OutgoingPayload(texts: [s]), to: t.id); target = nil }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 50, matching: nil)
            .onChange(of: photoItems) { _, items in sendPhotos(items) }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, let t = target { sendFiles(urls, to: t.id) }
                target = nil; showFiles = false
            }
            .sheet(item: $model.incoming) { state in
                IncomingSheet(state: state, model: model)
                    .presentationDetents([.height(420)])
                    .presentationCornerRadius(28)
                    .interactiveDismissDisabled(state.phase == .asking || state.phase == .receiving)
            }
            .alert(model.message.map { "Message from “\($0.sender)”" } ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("Copy") { UIPasteboard.general.string = model.message?.text }
                Button("Close", role: .cancel) {}
            } message: { Text(model.message?.text ?? "") }
        }
    }

    private func sendFiles(_ urls: [URL], to peerID: String) {
        // Copy out of the security scope so the transfer can read them at its own pace.
        var local: [URL] = []
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = AppPaths.newStageFile(named: u.lastPathComponent)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { local.append(dest) }
        }
        model.send(OutgoingPayload(fileURLs: local), to: peerID)
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) {
        guard let t = target, !items.isEmpty else { return }
        let peerID = t.id
        target = nil; showPhotos = false
        Task {
            var urls: [URL] = []
            for item in items {
                if let file = try? await item.loadTransferable(type: MediaFile.self) { urls.append(file.url) }
            }
            photoItems = []
            model.send(OutgoingPayload(fileURLs: urls), to: peerID)
        }
    }
}

/// Photos/videos exported to a real file (keeps HEIC/ProRAW/video originals).
struct MediaFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dest = AppPaths.newStageFile(named: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MediaFile(url: dest)
        }
    }
}

/// The AirDrop accept card.
struct IncomingSheet: View {
    @ObservedObject var state: IncomingState
    let model: PhoneModel

    var body: some View {
        VStack(spacing: 18) {
            Text("SwiftDrop").font(.headline).padding(.top, 22)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 120, height: 120)
                    .overlay(Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary))
                if state.offer.files.count > 1 {
                    Text("\(state.offer.files.count)").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.airDropBlue)).offset(x: 8, y: 6)
                }
            }
            Text(title).font(.body).multilineTextAlignment(.center).padding(.horizontal, 24)
            switch state.phase {
            case .asking:
                Toggle("Always accept from this device", isOn: $state.alwaysAccept)
                    .font(.footnote).padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button { model.respond(.decline) } label: { Text("Decline").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.bordered)
                    Button { model.respond(.accept) } label: { Text("Accept").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large).padding(.horizontal, 24)
            case .receiving:
                ProgressView(value: state.progress).padding(.horizontal, 40).tint(.airDropBlue)
            case .done:
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(Color.airDropBlue)
                Button("Done") { model.incoming = nil }.buttonStyle(.borderedProminent).controlSize(.large)
            case .failed:
                Text(state.error ?? "Failed").foregroundStyle(.red)
                Button("Close") { model.incoming = nil }.buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        let f = state.offer.files
        if f.allSatisfy({ $0.mimeType.hasPrefix("image/") }) { return "photo.on.rectangle" }
        if f.allSatisfy({ $0.mimeType.hasPrefix("video/") }) { return "video" }
        return "doc"
    }

    private var title: String {
        let o = state.offer
        let n = o.files.count
        let noun: String
        if o.files.allSatisfy({ $0.mimeType.hasPrefix("image/") }) { noun = n == 1 ? "a photo" : "\(n) photos" }
        else if o.files.allSatisfy({ $0.mimeType.hasPrefix("video/") }) { noun = n == 1 ? "a video" : "\(n) videos" }
        else { noun = n == 1 ? "“\(o.files[0].name)”" : "\(n) items" }
        switch state.phase {
        case .asking: return "“\(o.senderAlias)” would like to share \(noun)."
        case .receiving: return "Receiving \(noun) from “\(o.senderAlias)”…"
        case .done: return "Received \(noun) from “\(o.senderAlias)”."
        case .failed: return "Couldn’t receive \(noun)."
        }
    }
}
