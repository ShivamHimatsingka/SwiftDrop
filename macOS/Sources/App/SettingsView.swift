import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("This Mac") {
                TextField("Device name", text: $model.deviceName)
                Picker("Receive from", selection: $model.receiveMode) {
                    ForEach(ReceiveMode.allCases) { Text($0.longTitle).tag($0) }
                }
                LabeledContent("Save received files to") {
                    HStack {
                        Text(model.saveDirectory.lastPathComponent).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Play sounds", isOn: $model.playSounds)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section {
                Toggle("Encryption (HTTPS)", isOn: $model.useEncryption)
                Picker("Direct Wi‑Fi link", selection: $model.directLink) {
                    ForEach(DirectLinkPreference.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Protocol", value: "LocalSend v\(LocalSendConstants.protocolVersion) · port \(LocalSendConstants.port)")
                if let fp = model.localSend?.fingerprint {
                    LabeledContent("Fingerprint") {
                        Text(fp.prefix(16) + "…").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: { Text("Network") } footer: {
                Text("Direct Wi‑Fi link connects straight to nearby iPhones, iPads and Macs (like AirDrop) without leaving your network. Automatic uses it only when the normal network can't reach the device. Bluetooth is used to find devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Favorites") {
                if model.favorites.isEmpty {
                    Text("Right-click a nearby device to add it to Favorites.").foregroundStyle(.secondary)
                }
                ForEach($model.favorites) { $fav in
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(fav.alias)
                        Spacer()
                        Toggle("Auto-accept", isOn: $fav.autoAccept).toggleStyle(.checkbox)
                        Button { model.favorites.removeAll { $0.id == fav.id } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = model.saveDirectory
        p.prompt = "Choose"
        if p.runModal() == .OK, let url = p.url { model.saveDirectoryPath = url.path }
    }
}
