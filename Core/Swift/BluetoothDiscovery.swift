import Foundation
import CoreBluetooth

/// SwiftDrop's Bluetooth LE discovery, shared by every platform:
///  • advertise service `SwiftDropBLE.service`
///  • GATT characteristic `SwiftDropBLE.info` (read) returns a small JSON card:
///      {"a":alias,"f":fingerprint,"m":model,"t":type,"p":port,"s":scheme,"ip":["192.168.1.5"],"x":["awdl"]}
/// Peers read the card, then connect over Wi‑Fi (LAN IP or a direct link).
/// This finds devices on networks that block multicast, and wakes direct links.
enum SwiftDropBLE {
    static let service = CBUUID(string: "7A4F0001-5D3F-4B6E-9C2A-53574946544F")
    static let info = CBUUID(string: "7A4F0002-5D3F-4B6E-9C2A-53574946544F")
}

struct BLECard: Codable, Sendable {
    var a: String          // alias
    var f: String          // fingerprint
    var m: String?         // model
    var t: String?         // device type
    var p: Int             // port
    var s: String          // scheme
    var ip: [String]       // IPv4 addresses
    var x: [String]        // direct-link capabilities: "awdl" (Apple), "wfd" (Wi‑Fi Direct)
}

final class BluetoothDiscovery: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// Supplies our card (nil = don't advertise right now).
    var card: (@Sendable () -> BLECard?)?
    var onCard: (@Sendable (BLECard) -> Void)?

    private let queue = DispatchQueue(label: "swiftdrop.ble")
    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var serviceAdded = false
    private var advertise = true
    private var connecting: [UUID: CBPeripheral] = [:]
    private var lastRead: [UUID: Date] = [:]
    private var readBuffers: [UUID: Data] = [:]

    func start(advertise: Bool) {
        self.advertise = advertise
        queue.async {
            if advertise { self.peripheral = CBPeripheralManager(delegate: self, queue: self.queue) }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.peripheral?.stopAdvertising()
            self.central?.stopScan()
            self.connecting.values.forEach { self.central?.cancelPeripheralConnection($0) }
        }
    }

    /// Re-scan (e.g. when a sending UI opens) and re-evaluate advertising.
    func refresh() {
        queue.async {
            self.updateAdvertising()
            self.lastRead.removeAll()
            if self.central?.state == .poweredOn { self.scan() }
        }
    }

    // MARK: Advertising (peripheral)

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        SDLog.log("Bluetooth advertising ready")
        if !serviceAdded {
            let ch = CBMutableCharacteristic(type: SwiftDropBLE.info, properties: [.read], value: nil, permissions: [.readable])
            let svc = CBMutableService(type: SwiftDropBLE.service, primary: true)
            svc.characteristics = [ch]
            p.add(svc)
            serviceAdded = true
        }
        updateAdvertising()
    }

    private func updateAdvertising() {
        guard let p = peripheral, p.state == .poweredOn else { return }
        let visible = card?() != nil
        if visible && !p.isAdvertising {
            p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SwiftDropBLE.service],
                                CBAdvertisementDataLocalNameKey: "SwiftDrop"])
        } else if !visible && p.isAdvertising {
            p.stopAdvertising()
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == SwiftDropBLE.info, let c = card?(),
              let data = try? JSONEncoder().encode(c) else {
            p.respond(to: request, withResult: .attributeNotFound); return
        }
        guard request.offset <= data.count else { p.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count)
        p.respond(to: request, withResult: .success)
    }

    // MARK: Scanning (central)

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        SDLog.log("Bluetooth state \(c.state.rawValue) (5 = on), authorization \(CBManager.authorization.rawValue) (3 = allowed)")
        if c.state == .poweredOn { scan() }
    }

    private func scan() {
        central?.scanForPeripherals(withServices: [SwiftDropBLE.service],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        // Read each device's card at most once a minute.
        if let t = lastRead[p.identifier], Date().timeIntervalSince(t) < 60 { return }
        guard connecting[p.identifier] == nil, connecting.count < 4 else { return }
        lastRead[p.identifier] = Date()
        connecting[p.identifier] = p
        p.delegate = self
        c.connect(p)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in   // give up on slow peers
            if let p = self?.connecting.removeValue(forKey: p.identifier) { self?.central?.cancelPeripheralConnection(p) }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([SwiftDropBLE.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connecting[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connecting[p.identifier] = nil
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == SwiftDropBLE.service }) else { return finish(p) }
        p.discoverCharacteristics([SwiftDropBLE.info], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == SwiftDropBLE.info }) else { return finish(p) }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        defer { finish(p) }
        guard let data = ch.value, let c = try? JSONDecoder().decode(BLECard.self, from: data) else { return }
        SDLog.log("Bluetooth card from \(c.a) (\(c.ip.joined(separator: ", ")))")
        onCard?(c)
    }

    private func finish(_ p: CBPeripheral) {
        connecting[p.identifier] = nil
        central?.cancelPeripheralConnection(p)
    }
}
