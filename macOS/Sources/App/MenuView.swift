import SwiftUI
import AppKit

/// Menu bar popover modelled on Control Center's AirDrop module:
/// switch + "Favorites Only / Everyone" checkmark rows, then nearby people.
struct MenuView: View {
    @ObservedObject var model: AppModel
    let controller: StatusItemController
    @State private var clipboard: (symbol: String, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if model.receiveMode != .off {
                VStack(spacing: 0) {
                    ModeRow(title: "Favorites Only", selected: model.receiveMode == .favorites) {
                        model.receiveMode = .favorites
                    }
                    ModeRow(title: "Everyone", selected: model.receiveMode == .everyone) {
                        model.receiveMode = .everyone
                    }
                }
                .padding(.horizontal, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            separator
            if let pending = model.pendingPayload { pendingBanner(pending).padding(.horizontal, 14).padding(.bottom, 8) }
            if let msg = model.statusMessage { warning(msg).padding(.horizontal, 14).padding(.bottom, 8) }
            nearby.padding(.horizontal, 10)
            if !model.peers.isEmpty {
                separator
                MenuRow(symbol: clipboard?.symbol ?? "doc.on.clipboard",
                        title: "Send Clipboard", detail: clipboard?.text ?? "Clipboard is empty") {
                    EmptyView()
                }
                .overlay(alignment: .trailing) { clipboardTargets.padding(.trailing, 14) }
                .padding(.horizontal, 6)
            }
            if !model.history.isEmpty {
                separator
                recent.padding(.horizontal, 6)
            }
            separator
            VStack(spacing: 0) {
                PlainMenuItem(title: "SwiftDrop Settings…") { controller.openSettings() }
                PlainMenuItem(title: "Quit SwiftDrop") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: 330)
        .animation(.snappy(duration: 0.25), value: model.receiveMode)
        .animation(.snappy(duration: 0.25), value: model.peers.map(\.id))
        .onAppear { clipboard = model.clipboardSummary() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if model.popoverVisible { model.sendingUIStillOpen() }   // live online / Asleep status
        }
    }

    private var separator: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Header (Control Center style)

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(model.receiveMode == .off ? AnyShapeStyle(Color.primary.opacity(0.12))
                                                       : AnyShapeStyle(Color.airDropBlue))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.receiveMode == .off ? Color.primary : Color.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("SwiftDrop").font(.system(size: 13, weight: .semibold))
                Text(model.receiveMode == .off ? "Receiving Off" : model.receiveMode.longTitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.receiveMode != .off },
                                     set: { model.receivingEnabled = $0 }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .focusEffectDisabled()
        }
    }

    private func pendingBanner(_ p: OutgoingPayload) -> some View {
        HStack(spacing: 8) {
            Image(systemName: p.fileURLs.isEmpty ? "text.bubble.fill" : "doc.fill")
                .foregroundStyle(Color.airDropBlue)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("Click a person to send").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.pendingPayload = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.airDropBlue.opacity(0.12)))
    }

    private func warning(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.statusMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Nearby (AirDrop grid)

    private var nearby: some View {
        Group {
            if model.peers.isEmpty {
                VStack(spacing: 6) {
                    RadarView(size: 96)
                    Text("Looking for people nearby…").font(.system(size: 12, weight: .medium))
                    Text("Devices running LocalSend on this Wi‑Fi appear here.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Search Again") { model.sendingUIDidAppear(deep: true) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: 4),
                          spacing: 10) {
                    ForEach(model.peers) { peer in
                        let t = model.transfer(for: peer.id)
                        DeviceTile(alias: peer.alias, deviceType: peer.deviceType, deviceModel: peer.deviceModel,
                                   phase: t?.phase ?? .idle, progress: t?.progress ?? 0,
                                   isFavorite: model.isFavorite(peer.id), asleep: peer.asleep, size: 50) {
                            tap(peer)
                        }
                        .contextMenu { contextMenu(peer, transfer: t) }
                        .help(t?.message ?? peer.alias)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private func contextMenu(_ peer: Peer, transfer: OutgoingTransfer?) -> some View {
        if transfer?.phase.isActive == true {
            Button("Stop Sending") { model.cancelTransfer(forPeer: peer.id) }
            Divider()
        }
        Button("Send Files…") { controller.pickFilesAndSend(to: peer.id) }
        Button("Send Clipboard") { model.sendClipboard(to: peer.id) }
        Divider()
        Button(model.isFavorite(peer.id) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(peer) }
        if model.isFavorite(peer.id) {
            let auto = model.favorites.first { $0.id == peer.id }?.autoAccept ?? false
            Toggle("Auto-Accept from This Device", isOn: Binding(get: { auto }, set: {
                model.setFavorite(id: peer.id, alias: peer.alias, autoAccept: $0)
            }))
        }
    }

    private func tap(_ peer: Peer) {
        if let t = model.transfer(for: peer.id), t.phase.isActive { return }
        if let pending = model.pendingPayload {
            model.send(pending, to: peer.id)
            model.pendingPayload = nil
        } else {
            controller.pickFilesAndSend(to: peer.id)
        }
    }

    // MARK: Clipboard

    private var clipboardTargets: some View {
        HStack(spacing: 4) {
            ForEach(model.peers.prefix(3)) { peer in
                let t = model.transfer(for: peer.id)
                Button { model.sendClipboard(to: peer.id) } label: {
                    DeviceAvatar(alias: peer.alias, deviceType: peer.deviceType, deviceModel: peer.deviceModel,
                                 phase: t?.phase ?? .idle, progress: t?.progress ?? 0, size: 22)
                }
                .buttonStyle(.plain)
                .help("Send clipboard to \(peer.alias)")
                .disabled(clipboard == nil)
            }
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearHistory() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.bottom, 2)
            ForEach(model.history.prefix(4)) { item in
                HistoryRow(item: item) { model.open(item) }
            }
        }
    }
}

// MARK: - Control Center-style rows

private struct ModeRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PlainMenuItem: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack { Text(title).font(.system(size: 13)); Spacer() }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct MenuRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1))
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.system(size: 12)).lineLimit(1)
                    Text("\(item.direction == .sent ? "To" : "From") \(item.deviceAlias) · \(item.date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: item.direction == .sent ? "arrow.up.circle" : "arrow.down.circle")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.paths.isEmpty ? "Copy text" : "Show in Finder")
    }

    @ViewBuilder private var icon: some View {
        if let p = item.paths.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable()
        } else {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1))
                Image(systemName: "text.bubble").font(.system(size: 11))
            }
        }
    }
}
