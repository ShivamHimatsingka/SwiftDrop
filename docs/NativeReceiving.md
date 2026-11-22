# Making the receiving side "AirDrop-native"

**Goal:** the other device should not have to open any app to be discovered
or to receive. It should get an OS-level prompt the way an iPhone does for AirDrop.

## Where each platform stands

| Receiver | Built-in OS transport | Can SwiftDrop use it? | Plan |
|---|---|---|---|
| **Android** | **Quick Share** (formerly Nearby Share), part of Google Play services. No app to open. | **Yes, it's feasible.** The protocol has been reverse-engineered (open-source: NearDrop for macOS, rquickshare for Linux). | `QuickShareTransport` (phase 2–3) |
| **Windows** | "Nearby sharing" uses a proprietary, undocumented CDP protocol. Google's *Quick Share for Windows* app runs in the tray at login. | Through Quick Share for Windows: same protocol as Android. | Covered by `QuickShareTransport` |
| **Linux** | None | Not without software on the device | Optional headless background agent (phase 4) |
| **iOS / iPadOS** | AirDrop only (closed) | No. Apple doesn't let third parties use AirDrop. | LocalSend app (foreground) |
| **Any device with LocalSend** | — | Yes (shipping today) | On desktop, set LocalSend to *start at login, minimised to tray*: it's always discoverable and you never have to open it |

What works today: the SwiftDrop apps for Android, Windows and macOS receive in the
background with nothing open (Android: foreground service + Quick Settings tile,
started at boot; Windows: tray app started at login; macOS: menu bar app). They
interoperate with every LocalSend device. iOS can only receive while SwiftDrop is open.
Quick Share is the only way to reach a stock Android phone that has nothing installed.

## Architecture that's already in place

* `Core/Swift/Transport.swift`: the `NearbyTransport` protocol. It has peers,
  `send(_:to:update:)`, start/stop/refresh, and `requiresCompanionAppOnPeer`
  (this flag is `false` for OS-native transports, so the UI can show them as "native").
* `TransportHost` (implemented by `AppModel`) owns the receive policy
  (Off / Favorites / Everyone, auto-accept favourites), the Accept/Decline
  prompt, progress, history and sounds. Any new transport reuses all of it.
* `macOS/Sources/App/QuickShareTransport.swift`: an inert scaffold that's registered
  behind the `SwiftDropExperimentalQuickShare` user default.
* The UI, the share extension and the control API all address peers by
  `Peer.id` + `Peer.transportID`, so Quick Share peers will just show up next to LocalSend ones.

## Phase 2: Android → Mac with Quick Share (receive)

Android lists the Mac in its own share sheet, and the user taps it. Nothing is installed on the phone.

1. **Advertise** a Bonjour service over Wi-Fi LAN (`NWListener.service`) of
   type `_FC9F5ED42C8A._tcp`. The service *name* encodes a random 4-byte
   endpoint id. TXT record `n` carries base64url "endpoint info": a device-type
   bit (laptop) plus the display name.
2. **Connection layer (Nearby Connections):** frames are 4-byte big-endian
   length + protobuf (`offline_wire_formats.proto`: `ConnectionRequest`,
   `ConnectionResponse`, `PayloadTransfer`, `KeepAlive`).
3. **UKEY2 handshake:** ECDH P-256, then HKDF-SHA256 derives the session keys
   (CryptoKit covers all of it: `P256.KeyAgreement`, `HKDF`, `AES` and `HMAC`).
   After that, every frame is a `SecureMessage` (AES-256-CBC + HMAC-SHA256).
   The 4-digit PIN shown on the phone comes from the auth string.
4. **Sharing layer** (`wire_format.proto`): `PairedKeyEncryption` (we answer with
   an "unable to verify" result, as NearDrop does, so it works without a Google
   account), `Introduction` (file/text metadata), then our `Response(ACCEPT)`.
   That reply is driven by `host.transportShouldAccept(offer)`, which shows the
   existing Accept/Decline prompt.
5. **Payload:** chunked `PayloadTransfer` frames get streamed to the save
   directory with the same partial-file + rename logic as `LocalSendTransport`.

Protobuf: write a minimal hand-rolled encoder/decoder for the ~15 messages
involved. This avoids pulling in SwiftProtobuf and keeps the app lightweight.

Reference implementations to verify the exact field numbers and the name/TXT encoding against:
NearDrop (`PROTOCOL.md`, Swift, macOS) and rquickshare (Rust).

## Phase 3: Mac → Android with Quick Share (send)

1. Browse for `_FC9F5ED42C8A._tcp` with `NWBrowser`, decode endpoint info,
   and emit `Peer(transportID: "quickshare")`.
2. Connect, run UKEY2 as the client, send `Introduction`, wait for the
   receiver's accept (phase `.waiting` → existing progress ring), then stream payloads.
3. **Known risk:** Android normally publishes its mDNS service only once
   something has woken it up, usually a nearby sender's BLE "fast init"
   advertisement (service UUID `0xFE2C`). `CBPeripheralManager` on macOS can't
   broadcast arbitrary service data, so a Mac may only find phones that are
   already advertising (Quick Share open, or visibility set to "Everyone").
   Prototype this early: it decides whether "no app open on the phone" holds for
   Mac → Android, or only for Android → Mac.

## Phase 4 (optional): background agents for Linux / Windows

For machines without Quick Share: a tiny headless daemon (systemd user unit /
Windows service) that speaks **LocalSend v2**, so SwiftDrop needs no changes.
It answers discovery and raises a native OS notification with Accept/Decline.
It's installed once and never opened again.

## Milestones / definition of done

- [ ] Phase 2: a stock Pixel and a Samsung (Quick Share, visibility "Everyone")
      see the Mac and send a photo; the Mac prompt works and auto-accept for favourites works.
- [ ] Phase 3: the Mac sends a file to a phone whose Quick Share is idle; record whether the BLE wake is needed.
- [ ] Interop matrix: LocalSend (Android/Windows/Linux/iOS) + Quick Share (Android/Windows).
