import Foundation
import Combine

enum ReceiveMode: String, CaseIterable, Identifiable, Codable {
    case off, favorites, everyone
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .favorites: "Favorites"; case .everyone: "Everyone" }
    }
    var longTitle: String {
        switch self { case .off: "Receiving Off"; case .favorites: "Favorites Only"; case .everyone: "Everyone" }
    }
}

struct Favorite: Codable, Identifiable, Hashable {
    var id: String
    var alias: String
    var autoAccept: Bool
}

struct HistoryItem: Codable, Identifiable, Hashable {
    enum Direction: String, Codable { case sent, received }
    var id = UUID()
    var date = Date()
    var direction: Direction
    var title: String
    var deviceAlias: String
    var paths: [String]
    var text: String?
}

struct OutgoingTransfer: Identifiable {
    let id: String
    let peerID: String
    var phase: TransferPhase
    var progress: Double
    var message: String?
    let started = Date()
    var title: String
}

final class IncomingState: ObservableObject, Identifiable {
    enum Phase { case asking, receiving, done, failed }
    let offer: IncomingOffer
    @Published var phase: Phase = .asking
    @Published var progress: Double = 0
    @Published var files: [URL] = []
    @Published var error: String?
    @Published var alwaysAccept = false
    var id: String { offer.id }
    init(offer: IncomingOffer) { self.offer = offer }
}

