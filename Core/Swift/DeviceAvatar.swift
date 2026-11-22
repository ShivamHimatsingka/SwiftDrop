import SwiftUI

enum DeviceGlyph {
    static func symbol(type: String?, model: String?) -> String {
        let m = (model ?? "").lowercased()
        switch (type ?? "").lowercased() {
        case "mobile":
            if m.contains("ipad") || m.contains("tablet") || m.contains("tab ") { return "ipad.landscape" }
            if m.contains("iphone") { return "iphone" }
            return "smartphone"
        case "web": return "globe"
        case "headless", "server": return "server.rack"
        default:
            if m.contains("macbook") { return "laptopcomputer" }
            if m.contains("mac") { return "desktopcomputer" }
            if m.contains("windows") { return "pc" }
            return "desktopcomputer"
        }
    }

    /// Secondary line under the name, like AirDrop's "iPhone" / "MacBook Pro".
    static func caption(type: String?, model: String?) -> String {
        if let m = model, !m.isEmpty { return m }
        switch (type ?? "").lowercased() {
        case "mobile": return "Phone"
        case "web": return "Browser"
        case "headless", "server": return "Server"
        default: return "Computer"
        }
    }

    /// Contacts-style monogram (max two letters).
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "’" || $0 == "'" })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// AirDrop blue.
extension Color {
    static let airDropBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
}

/// AirDrop-style monogram avatar with the thin blue progress ring.
struct DeviceAvatar: View {
    var alias: String
    var deviceType: String?
    var deviceModel: String?
    var phase: TransferPhase = .idle
    var progress: Double = 0
    var isFavorite: Bool = false
    var size: CGFloat = 64
    var highlighted: Bool = false

    private var ringWidth: CGFloat { max(2, size * 0.045) }
    private var gap: CGFloat { max(1.5, size * 0.035) }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.66, green: 0.68, blue: 0.73),
                                              Color(red: 0.52, green: 0.54, blue: 0.59)],
                                     startPoint: .top, endPoint: .bottom))
                .brightness(highlighted ? -0.07 : 0)
            if size >= 30 {
                Text(DeviceGlyph.initials(alias))
                    .font(.system(size: size * 0.38, weight: .medium, design: .default))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: DeviceGlyph.symbol(type: deviceType, model: deviceModel))
                    .font(.system(size: size * 0.48))
                    .foregroundStyle(.white)
            }
            ring.frame(width: size + (gap + ringWidth) * 2, height: size + (gap + ringWidth) * 2)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if size >= 30 {
                // Small device badge, like AirDrop's device indicator.
                Image(systemName: isFavorite ? "star.fill" : DeviceGlyph.symbol(type: deviceType, model: deviceModel))
                    .font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .background(Circle().fill(.background))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .padding(gap + ringWidth)
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    @ViewBuilder private var ring: some View {
        switch phase {
        case .waiting:
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: ringWidth)
                SpinningArc(width: ringWidth)
            }
        case .sending:
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0, to: max(0.01, min(1, progress)))
                    .stroke(Color.airDropBlue, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: progress)
            }
        default:
            EmptyView()
        }
    }
}

private struct SpinningArc: View {
    let width: CGFloat
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.18)
            .stroke(Color.airDropBlue, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// AirDrop device cell: avatar, name, and a secondary line that turns into
/// the blue "Waiting… / Sending… / Sent" status.
struct DeviceTile: View {
    var alias: String
    var deviceType: String?
    var deviceModel: String?
    var phase: TransferPhase = .idle
    var progress: Double = 0
    var isFavorite: Bool = false
    /// Locked iPhone: still sendable (it gets woken), shown dimmed with "Asleep".
    var asleep: Bool = false
    var size: CGFloat = 64
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                DeviceAvatar(alias: alias, deviceType: deviceType, deviceModel: deviceModel,
                             phase: phase, progress: progress, isFavorite: isFavorite,
                             size: size, highlighted: hovering)
                    .opacity(asleep && phase == .idle ? 0.55 : 1)
                Text(alias)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Text(secondary)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(secondaryColor)
                    .contentTransition(.opacity)
            }
            .frame(width: size + 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .allowsHitTesting(!phase.isActive)
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private var secondary: String {
        switch phase {
        case .idle: return asleep ? "Asleep" : DeviceGlyph.caption(type: deviceType, model: deviceModel)
        case .sending where progress > 0: return "Sending… \(Int(progress * 100))%"
        default: return phase.label ?? ""
        }
    }

    private var secondaryColor: Color {
        switch phase {
        case .idle: return .secondary
        case .declined, .failed: return .red
        case .cancelled: return .secondary
        default: return .airDropBlue
        }
    }
}

/// The AirDrop "radar": soft concentric rings pulsing out from a blue glyph.
struct RadarView: View {
    var size: CGFloat = 120
    var active: Bool = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.airDropBlue.opacity(0.35), lineWidth: 1)
                    .scaleEffect(pulse ? 1.0 : 0.35)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(active ? .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8)
                                      : .default, value: pulse)
            }
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.66, blue: 1.0), .airDropBlue],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.36, height: size * 0.36)
                .shadow(color: .airDropBlue.opacity(0.35), radius: 4, y: 1)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: size * 0.15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .onAppear { if active { pulse = true } }
    }
}
