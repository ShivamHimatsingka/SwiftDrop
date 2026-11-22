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
    /// Held connection ("link"): an iPhone stays connected to nearby senders and subscribes here.
    /// It writes its card once; to knock, the sender notifies "k" and the iPhone reads the knock back.
    /// iOS wakes a locked/suspended app for that notification, however long it has been locked.
    static let link = CBUUID(string: "7A4F0005-5D3F-4B6E-9C2A-53574946544F")
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

    // Links, receiving side (iPhone): connections we hold to nearby senders.
    private var linkMode = false
    private var links: [UUID: CBPeripheral] = [:]
    private var linkOwner: [UUID: String] = [:]                // peripheral -> their fingerprint
    private static let maxLinks = 8
    // Links, sending side: iPhones holding a connection to us.
    private var linkChar: CBMutableCharacteristic?
    private var resetService = false
    private var linkedCentrals: [String: CBCentral] = [:]     // fingerprint -> subscribed central
    private var knockFor: [UUID: Data] = [:]                  // central -> knock it should read
    private var knockWaiter: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var notifyBacklog: [CBCentral] = []
    private var subscribed: [UUID: CBCentral] = [:]          // central id -> the object CoreBluetooth subscribed

    // Lightweight scanning: short bursts instead of a permanent scan.
    private var scanning = false
    private var scanUntil = Date.distantPast
    private var burstTimer: DispatchSourceTimer?
    private static let cardTTL: TimeInterval = 300            // re-read a device's card at most every 5 min

    func start(advertise: Bool, link: Bool = false) {
        self.advertise = advertise
        self.linkMode = link
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
            #if os(iOS)
            let copts: [String: Any] = link ? [CBCentralManagerOptionRestoreIdentifierKey: "swiftdrop.central"] : [:]
            #else
            let copts: [String: Any] = [:]
            #endif
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: copts)
        }
    }

    func stop() {
        queue.async {
            self.burstTimer?.cancel(); self.burstTimer = nil
            self.peripheral?.stopAdvertising()
            self.central?.stopScan(); self.scanning = false
            self.connecting.values.forEach { self.central?.cancelPeripheralConnection($0) }
            self.links.values.forEach { self.central?.cancelPeripheralConnection($0) }
            self.links.removeAll()
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
            guard let self, self.scanning, Date() >= self.scanUntil, !self.linkMode else { return }
            self.central?.stopScan(); self.scanning = false
        }
    }

    // MARK: Advertising (peripheral)

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        SDLog.log("Bluetooth advertising ready")
        if resetService { p.removeAllServices(); serviceAdded = false; resetService = false }
        if !serviceAdded {
            let ch = CBMutableCharacteristic(type: SwiftDropBLE.info, properties: [.read], value: nil, permissions: [.readable])
            let wake = CBMutableCharacteristic(type: SwiftDropBLE.wake, properties: [.write], value: nil, permissions: [.writeable])
            let link = CBMutableCharacteristic(type: SwiftDropBLE.link, properties: [.read, .write, .notify],
                                               value: nil, permissions: [.readable, .writeable])
            linkChar = link
            let svc = CBMutableService(type: SwiftDropBLE.service, primary: true)
            svc.characteristics = [ch, wake, link]
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
           let svc = services.first(where: { $0.uuid == SwiftDropBLE.service }) {
            if let link = svc.characteristics?.first(where: { $0.uuid == SwiftDropBLE.link }) as? CBMutableCharacteristic {
                linkChar = link; serviceAdded = true
            } else {
                resetService = true          // restored from an older version: re-add with the link characteristic
            }
        }
        SDLog.log("Bluetooth state restored")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // An iPhone linked to us and sent its card (may arrive in pieces for long writes).
        let linkParts = requests.filter { $0.characteristic.uuid == SwiftDropBLE.link }.sorted { $0.offset < $1.offset }
        if let central = linkParts.first?.central {
            let data = linkParts.reduce(into: Data()) { $0.append($1.value ?? Data()) }
            if data == Data("ack".utf8) { knockDone(central.identifier, true) }      // the iPhone got our knock
            else if let card = try? JSONDecoder().decode(BLECard.self, from: data) {
                linkedCentrals = linkedCentrals.filter { $0.value.identifier != central.identifier }
                linkedCentrals[card.f] = subscribed[central.identifier] ?? central
                SDLog.log("Bluetooth link from \(card.a) (\(linkedCentrals.count) linked)")
                onCard?(card)
            }
        }
        for r in requests where r.characteristic.uuid == SwiftDropBLE.wake {
            if let v = r.value, let w = try? JSONDecoder().decode(BLEWake.self, from: v) {
                SDLog.log("Bluetooth wake from \(w.a): \(w.n)")
                onWake?(w)
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == SwiftDropBLE.link else { return }
        subscribed[central.identifier] = central
        // The card write may have come first: point that link at the subscribed central.
        for (fp, c) in linkedCentrals where c.identifier == central.identifier { linkedCentrals[fp] = central }
        SDLog.log("Bluetooth link subscribed (max update \(central.maximumUpdateValueLength) bytes)")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == SwiftDropBLE.link else { return }
        subscribed[central.identifier] = nil
        if let fp = linkedCentrals.first(where: { $0.value.identifier == central.identifier })?.key {
            linkedCentrals[fp] = nil
            SDLog.log("Bluetooth link dropped (\(fp.prefix(8)))")
        }
        knockDone(central.identifier, false)
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        guard let ch = linkChar else { return }
        while let c = notifyBacklog.first,
              p.updateValue(knockFor[c.identifier].flatMap { $0.count <= c.maximumUpdateValueLength ? $0 : nil } ?? Data("k".utf8),
                            for: ch, onSubscribedCentrals: [c]) {
            notifyBacklog.removeFirst()
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == SwiftDropBLE.link {
            // A linked iPhone woke up and reads the knock we tapped it for.
            guard let data = knockFor[request.central.identifier] else { p.respond(to: request, withResult: .attributeNotFound); return }
            guard request.offset <= data.count else { p.respond(to: request, withResult: .invalidOffset); return }
            request.value = data.subdata(in: request.offset..<data.count)
            p.respond(to: request, withResult: .success)
            if request.offset == 0 { knockDone(request.central.identifier, true) }
            return
        }
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
        guard c.state == .poweredOn else { return }
        burst(20)
        if linkMode { links.values.filter { $0.state != .connected }.forEach { c.connect($0) } }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us (e.g. a sender tapped a link): take the held connections back.
        for p in (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? [] {
            p.delegate = self
            links[p.identifier] = p
        }
        SDLog.log("Bluetooth links restored (\(links.count))")
    }

    private func restartScan() {
        guard let c = central, c.state == .poweredOn else { return }
        c.stopScan(); scanning = false
        burst(20)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if linkMode {
            if links[p.identifier] != nil { return }
            if links.count < Self.maxLinks, card?() != nil {
                // Hold a connection so this sender can tap us later, even while we're locked.
                links[p.identifier] = p
                connecting[p.identifier] = nil
                p.delegate = self
                c.connect(p)                     // no timeout: iOS keeps it pending until in range
                return
            }
        }
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
        if links.removeValue(forKey: p.identifier) != nil { linkOwner[p.identifier] = nil; restartScan() }
        wakeDone(p, false)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connecting[p.identifier] = nil
        if links[p.identifier] != nil {
            // Out of range or restarted: wait for it to come back (same address), and rescan
            // in case it returns with a new address.
            c.connect(p)
            restartScan()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == SwiftDropBLE.service }) else { return finish(p) }
        p.discoverCharacteristics([SwiftDropBLE.info, SwiftDropBLE.wake, SwiftDropBLE.link], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let (payload, _) = pendingWake[p.identifier] {
            guard let ch = service.characteristics?.first(where: { $0.uuid == SwiftDropBLE.wake }) else { return wakeDone(p, false) }
            p.writeValue(payload, for: ch, type: .withResponse)
            return
        }
        if links[p.identifier] != nil {
            let chars = service.characteristics ?? []
            guard let link = chars.first(where: { $0.uuid == SwiftDropBLE.link }), let mine = card?(),
                  let data = try? JSONEncoder().encode(mine) else {
                // An older SwiftDrop without links, or we're not receiving: don't hold it.
                links[p.identifier] = nil
                central?.cancelPeripheralConnection(p)
                return
            }
            p.setNotifyValue(true, for: link)
            p.writeValue(data, for: link, type: .withResponse)
            if let info = chars.first(where: { $0.uuid == SwiftDropBLE.info }) { p.readValue(for: info) }
            return
        }
        guard let ch = service.characteristics?.first(where: { $0.uuid == SwiftDropBLE.info }) else { return finish(p) }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == SwiftDropBLE.link {
            SDLog.log("Bluetooth link notifications \(ch.isNotifying ? "on" : "off")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == SwiftDropBLE.wake { wakeDone(p, error == nil) }
        if ch.uuid == SwiftDropBLE.link { SDLog.log("Bluetooth link to \(linkOwner[p.identifier]?.prefix(8) ?? "device") \(error == nil ? "ready" : "failed: \(error!.localizedDescription)")") }
    }

    // MARK: Wake-up (sending side)

    /// True if we've read this device's card over Bluetooth and can knock on it.
    func canWake(_ fingerprint: String) -> Bool { queue.sync { peripheralFor[fingerprint] != nil || linkedCentrals[fingerprint] != nil } }

    /// That device holds a Bluetooth link to us right now (it's in range, even if locked).
    func isLinked(_ fingerprint: String) -> Bool { queue.sync { linkedCentrals[fingerprint] != nil } }

    /// Tap a linked iPhone: notify it, and wait until it reads the knock back.
    private func knockViaLink(_ fingerprint: String, _ payload: Data) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard let central = self.linkedCentrals[fingerprint], let ch = self.linkChar,
                      let p = self.peripheral, p.state == .poweredOn, self.knockWaiter[central.identifier] == nil else {
                    c.resume(returning: false); return
                }
                self.knockFor[central.identifier] = payload
                self.knockWaiter[central.identifier] = c
                let target = self.subscribed[central.identifier] ?? central
                let body = payload.count <= target.maximumUpdateValueLength ? payload : Data("k".utf8)
                let sent = p.updateValue(body, for: ch, onSubscribedCentrals: [target])
                if !sent { self.notifyBacklog.append(target) }
                SDLog.log("Bluetooth link: tapping \(fingerprint.prefix(8)) (subscribed: \(self.subscribed[central.identifier] != nil), queued: \(!sent))")
                self.queue.asyncAfter(deadline: .now() + 8) { self.knockDone(central.identifier, false) }
            }
        }
    }

    private func knockDone(_ id: UUID, _ ok: Bool) {
        guard let c = knockWaiter.removeValue(forKey: id) else { return }
        SDLog.log("Bluetooth link tap → \(ok ? "delivered" : "no answer")")
        if !ok {
            knockFor[id] = nil
            linkedCentrals = linkedCentrals.filter { $0.value.identifier != id }   // fall back to a direct knock
        } else {
            queue.asyncAfter(deadline: .now() + 30) { self.knockFor[id] = nil }
        }
        c.resume(returning: ok)
    }

    /// The saved peripheral didn't respond (its Bluetooth address rotated): forget it.
    func forget(_ fingerprint: String) { queue.async { self.peripheralFor[fingerprint] = nil } }

    /// Knock on a paused device over Bluetooth. Returns true when the write was acknowledged.
    func wake(_ fingerprint: String, _ knock: BLEWake) async -> Bool {
        guard let payload = try? JSONEncoder().encode(knock) else { return false }
        // Direct knock first: while the iPhone holds its link to us it stays reachable this way, and it's
        // fastest. The tap over the link is the backup.
        if queue.sync(execute: { peripheralFor[fingerprint] != nil || linkedCentrals[fingerprint] != nil }), await directKnock(fingerprint, payload) { return true }
        if queue.sync(execute: { linkedCentrals[fingerprint] != nil }) { return await knockViaLink(fingerprint, payload) }
        return false
    }

    private func directKnock(_ fingerprint: String, _ payload: Data) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard let id = self.peripheralFor[fingerprint] ?? self.linkedCentrals[fingerprint]?.identifier, let central = self.central, central.state == .poweredOn,
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
        if ch.uuid == SwiftDropBLE.link {
            // A sender tapped our link: read the knock (a 1-byte "k" is only the tap).
            SDLog.log("Bluetooth link update: \(ch.value?.count ?? 0) bytes\(error.map { ", error \($0.localizedDescription)" } ?? "")")
            guard let data = ch.value, error == nil else { return }
            if data == Data("k".utf8) { p.readValue(for: ch); return }
            if let w = try? JSONDecoder().decode(BLEWake.self, from: data) {
                SDLog.log("Bluetooth wake (link) from \(w.a): \(w.n)")
                p.writeValue(Data("ack".utf8), for: ch, type: .withResponse)
                onWake?(w)
            }
            return
        }
        defer { finish(p) }
        guard let data = ch.value, let c = try? JSONDecoder().decode(BLECard.self, from: data) else { return }
        peripheralFor[c.f] = p.identifier
        if links[p.identifier] != nil {
            // Same device under a new Bluetooth address: drop the old held connection.
            for (id, fp) in linkOwner where fp == c.f && id != p.identifier {
                if let old = links.removeValue(forKey: id) { central?.cancelPeripheralConnection(old) }
                linkOwner[id] = nil
            }
            linkOwner[p.identifier] = c.f
        }
        SDLog.log("Bluetooth card from \(c.a) (\(c.ip.joined(separator: ", ")))")
        onCard?(c)
    }

    private func finish(_ p: CBPeripheral) {
        connecting[p.identifier] = nil
        if links[p.identifier] != nil { return }          // held link: keep it
        if pendingWake[p.identifier] != nil { return }
        central?.cancelPeripheralConnection(p)
    }
}
