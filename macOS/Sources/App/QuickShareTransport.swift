import Foundation

/// Scaffold for an OS-native transport: Google Quick Share (formerly Nearby
/// Share), which is built into Android 6+ via Google Play services and
/// available on Windows. With it the receiving device needs **no app open** —
/// it is discovered and prompted by the OS, exactly like AirDrop.
///
/// Not enabled yet. The implementation plan (wire format, crypto, discovery,
/// milestones) lives in docs/NativeReceiving.md. When implemented, this class
/// plugs into `AppModel.transports` and its peers appear in the same UI.
///
/// Enable the (currently inert) scaffold with:
///   defaults write com.swiftdrop.app SwiftDropExperimentalQuickShare -bool YES
final class QuickShareTransport: NearbyTransport, @unchecked Sendable {
    let id = "quickshare"
    let displayName = "Quick Share"
    let requiresCompanionAppOnPeer = false
    var isAvailable: Bool { false }

    // Protocol constants (public knowledge from open-source implementations such
    // as NearDrop / rquickshare). Kept here so the implementation can start from them.
    enum Wire {
        /// mDNS service type: "_" + base32hex-ish of SHA-256("NearbySharing")[0..<6] → "_FC9F5ED42C8A._tcp"
        static let mdnsServiceType = "_FC9F5ED42C8A._tcp."
        /// Endpoint info TXT key carrying device type + name.
        static let txtEndpointInfoKey = "n"
        /// Service id used inside Nearby Connections frames.
        static let serviceID = "NearbySharing"
    }

    private weak var host: TransportHost?

    @MainActor func start(host: TransportHost) { self.host = host }
    @MainActor func stop() {}
    @MainActor func setAlias(_ alias: String) {}
    @MainActor func refresh(deep: Bool) {}

    func send(_ payload: OutgoingPayload, to peer: Peer, update: @escaping TransferUpdate) async throws {
        throw TransferError.unreachable("Quick Share transport is not implemented yet")
    }
}
