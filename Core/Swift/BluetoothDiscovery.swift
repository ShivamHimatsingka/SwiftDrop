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
    /// Write-only: "someone wants to send you something" — wakes a paused iPhone app.
    static let wake = CBUUID(string: "7A4F0004-5D3F-4B6E-9C2A-53574946544F")
}

/// Payload of a Bluetooth wake-up knock.
struct BLEWake: Codable, Sendable {
    var a: String     // sender alias
    var f: String     // sender fingerprint
    var n: String     // what (e.g. "3 Items", "photo.jpg")
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
    /// Someone knocked (receiving side). May run while the app is in the background.
    var onWake: (@Sendable (BLEWake) -> Void)?

    private let queue = DispatchQueue(label: "swiftdrop.ble")
    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var serviceAdded = false
    private var advertise = true
    private var connecting: [UUID: CBPeripheral] = [:]
    private var lastRead: [UUID: Date] = [:]
    private var peripheralFor: [String: UUID] = [:]          // fingerprint -> peripheral (from card reads)
    private var pendingWake: [UUID: (Data, CheckedContinuation<Bool, Never>)] = [:]

    // Lightweight scanning: short bursts instead of a permanent scan.
    private var scanning = false
    private var scanUntil = Date.distantPast
    private var burstTimer: DispatchSourceTimer?
    private static let cardTTL: TimeInterval = 300            // re-read a device's card at most every 5 min

    func start(advertise: Bool) {
        self.advertise = advertise
        queue.async { [weak self] in
            guard let self else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
            t.setEventHandler { [weak self] in self?.burst(15) }
            t.resume()
            self.burstTimer = t
            if advertise {
                #if os(iOS)
                let opts: [String: Any] = [CBPeripheralManagerOptionRestoreIdentifierKey: "swiftdrop.peripheral"]
                #else
                let opts: [String: Any] = [:]
                #endif
                self.peripheral = CBPeripheralManager(delegate: self, queue: self.queue, options: opts)
            }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.burstTimer?.cancel(); self.burstTimer = nil
            self.peripheral?.stopAdvertising()
            self.central?.stopScan(); self.scanning = false
            self.connecting.values.forEach { self.central?.cancelPeripheralConnection($0) }
        }
    }

    /// Visibility changed: start/stop advertising only (cheap; no scanning, no card reads).
    func visibilityChanged() { queue.async { self.updateAdvertising() } }

    /// A sending screen opened (or we need a fresh card): scan for a minute and re-read cards.
    func refresh() {
        queue.async {
            self.updateAdvertising()
            self.lastRead.removeAll()
            self.burst(60)
        }
    }

    /// Scan for `seconds`, then stop (extends a burst already running).
    private func burst(_ seconds: TimeInterval) {
        scanUntil = max(scanUntil, Date().addingTimeInterval(seconds))
        guard central?.state == .poweredOn else { return }
        if !scanning {
            central?.scanForPeripherals(withServices: [SwiftDropBLE.service],
                                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            scanning = true
        }
        queue.asyncAfter(deadline: .now() + seconds + 0.5) { [weak self] in
            guard let self, self.scanning, Date() >= self.scanUntil else { return }
            self.central?.stopScan(); self.scanning = false
        }
    }

    // MARK: Advertising (peripheral)

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        SDLog.log("Bluetooth advertising ready")
        if !serviceAdded {
            let ch = CBMutableCharacteristic(type: SwiftDropBLE.info, properties: [.read], value: nil, permissions: [.readable])
            let wake = CBMutableCharacteristic(type: SwiftDropBLE.wake, properties: [.write], value: nil, permissions: [.writeable])
            let svc = CBMutableService(type: SwiftDropBLE.service, primary: true)
            svc.characteristics = [ch, wake]
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

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a Bluetooth event: our service is restored with the manager.
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
           services.contains(where: { $0.uuid == SwiftDropBLE.service }) { serviceAdded = true }
        SDLog.log("Bluetooth state restored")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == SwiftDropBLE.wake {
            if let v = r.value, let w = try? JSONDecoder().decode(BLEWake.self, from: v) {
                SDLog.log("Bluetooth wake from \(w.a): \(w.n)")
                onWake?(w)
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
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
        scanning = false
        if c.state == .poweredOn { burst(20) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        // Read each device's card at most every few minutes (each read wakes a sleeping iPhone).
        if let t = lastRead[p.identifier], Date().timeIntervalSince(t) < Self.cardTTL { return }
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
        wakeDone(p, false)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connecting[p.identifier] = nil
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == SwiftDropBLE.service }) else { return finish(p) }
        p.discoverCharacteristics([SwiftDropBLE.info, SwiftDropBLE.wake], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let (payload, _) = pendingWake[p.identifier] {
            guard let ch = service.characteristics?.first(where: { $0.uuid == SwiftDropBLE.wake }) else { return wakeDone(p, false) }
            p.writeValue(payload, for: ch, type: .withResponse)
            return
        }
        guard let ch = service.characteristics?.first(where: { $0.uuid == SwiftDropBLE.info }) else { return finish(p) }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == SwiftDropBLE.wake { wakeDone(p, error == nil) }
    }

    // MARK: Wake-up (sending side)

    /// True if we've read this device's card over Bluetooth and can knock on it.
    func canWake(_ fingerprint: String) -> Bool { queue.sync { peripheralFor[fingerprint] != nil } }

    /// The saved peripheral didn't respond (its Bluetooth address rotated): forget it.
    func forget(_ fingerprint: String) { queue.async { self.peripheralFor[fingerprint] = nil } }

    /// Knock on a paused device over Bluetooth. Returns true when the write was acknowledged.
    func wake(_ fingerprint: String, _ knock: BLEWake) async -> Bool {
        guard let payload = try? JSONEncoder().encode(knock) else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard let id = self.peripheralFor[fingerprint], let central = self.central, central.state == .poweredOn,
                      let p = central.retrievePeripherals(withIdentifiers: [id]).first, self.pendingWake[id] == nil else {
                    c.resume(returning: false); return
                }
                self.pendingWake[id] = (payload, c)
                p.delegate = self
                if p.state == .connected { p.discoverServices([SwiftDropBLE.service]) } else { central.connect(p) }
                self.queue.asyncAfter(deadline: .now() + 15) { self.wakeDone(p, false) }
            }
        }
    }

    private func wakeDone(_ p: CBPeripheral, _ ok: Bool) {
        guard let (_, c) = pendingWake.removeValue(forKey: p.identifier) else { return }
        SDLog.log("Bluetooth wake → \(ok ? "delivered" : "failed")")
        central?.cancelPeripheralConnection(p)
        c.resume(returning: ok)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        defer { finish(p) }
        guard let data = ch.value, let c = try? JSONDecoder().decode(BLECard.self, from: data) else { return }
        peripheralFor[c.f] = p.identifier
        SDLog.log("Bluetooth card from \(c.a) (\(c.ip.joined(separator: ", ")))")
        onCard?(c)
    }

    private func finish(_ p: CBPeripheral) {
        connecting[p.identifier] = nil
        if pendingWake[p.identifier] != nil { return }
        central?.cancelPeripheralConnection(p)
    }
}
