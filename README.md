<p align="center"><img src="docs/icon.png" width="128" alt="SwiftDrop icon"></p>

# SwiftDrop

**AirDrop-style sharing between Mac, iPhone, Android and Windows.** It's native on every
platform and compatible with the open [LocalSend v2 protocol](https://github.com/localsend/protocol),
so it also works with every device that already runs LocalSend (Linux included).

| | Mac | iPhone / iPad | Android | Windows |
|---|---|---|---|---|
| Tech | Swift + SwiftUI | Swift + SwiftUI | Kotlin + Compose | .NET 8 + WPF |
| Send from the system share menu | Finder ▸ Share ▸ SwiftDrop | Share sheet ▸ SwiftDrop | Share ▸ SwiftDrop | Explorer ▸ right-click ▸ Send with SwiftDrop |
| Receive with nothing open | ✅ menu bar app, starts at login | ⚠️ app must be open (iOS restriction) | ✅ background service + Quick Settings tile | ✅ tray app, starts at login |
| Accept prompt | Notification-style banner | AirDrop-style card | Heads-up notification + card | Toast above the tray |
| Visibility | Off / Favorites / Everyone | Off / Favorites / Everyone | Off / Favorites / Everyone | Off / Favorites / Everyone |
| Size | 2.3 MB | 2.5 MB | 2 MB APK | 350 KB exe |

Everything streams straight to disk, so files of any size and any format work. Folders keep their structure.
Transfers are encrypted (HTTPS with per-device self-signed certificates, like LocalSend).
Favourites can be set to auto-accept.

---

## Install

Download from the [latest release](../../releases/latest).

### Mac (macOS 14+)
1. Download `SwiftDrop-macOS.zip`, unzip, and drag **SwiftDrop.app** to **Applications**.
2. First launch: right-click the app ▸ **Open** ▸ **Open**. It's ad-hoc signed, not notarized.
   Or run `xattr -dr com.apple.quarantine /Applications/SwiftDrop.app`.
3. Allow **Local Network** when asked. SwiftDrop lives in the menu bar (📡 icon).
4. **Finder ▸ Share ▸ SwiftDrop**: if it's missing, enable it in System Settings ▸ General ▸
   Login Items & Extensions ▸ Sharing. Settings ▸ "Open at login" keeps it always available.

### Android (Android 10+)
1. Download `SwiftDrop-Android.apk` on the phone and open it (allow "Install unknown apps" for your browser).
2. Open SwiftDrop once, allow **Notifications**, and pick **Everyone** or **Favorites Only**.
   From then on it receives in the background and restarts after reboot. You don't need to open it again.
3. Optional: pull down Quick Settings ▸ edit ✏️ ▸ drag the **SwiftDrop** tile in. Tap it to turn receiving on or off.
4. To send, use **Share ▸ SwiftDrop** from any app (Photos, Files, Chrome…).

### Windows 10/11
1. Install the free [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)
   (`winget install Microsoft.DotNet.DesktopRuntime.8`).
2. Download `SwiftDrop-Windows-x64.zip` (or `-arm64`), unzip anywhere permanent, run **SwiftDrop.exe**,
   and allow it through the Windows Firewall (Private networks).
3. It registers itself (per-user, no admin rights) to start at login and adds **Send with SwiftDrop**
   to Explorer's right-click menu. On Windows 11 that's under *Show more options*.
   Click the tray icon for the AirDrop-style panel. Drop files on it to send.

### iPhone / iPad (iOS 17+)
Apple doesn't allow installing apps outside the App Store or Xcode, so build it yourself (free Apple ID is enough):
1. Open `iOS/SwiftDrop.xcodeproj` in Xcode 16+.
2. For both targets (*SwiftDrop* and *SwiftDropShare*): Signing & Capabilities ▸ choose your Team
   (change the bundle IDs if Xcode asks).
3. Plug in your iPhone, select it, and press **Run**. Allow **Local Network** on first launch.
4. Send: **Share ▸ SwiftDrop** from Photos, Files, Safari… Receive: keep SwiftDrop open.
   Photos and videos you receive go to your Photos library; everything else goes to **Files ▸ On My iPhone ▸ SwiftDrop**.

### Linux / headless
Use the official LocalSend app, or the headless SwiftDrop peer (needs the .NET 8 runtime):
```bash
dotnet swiftdrop.dll serve --out ~/Downloads             # receive (asks before accepting)
dotnet swiftdrop.dll send 192.168.1.20 photo.jpg ~/Album  # send
```

---

## Platform notes (honest limits)

- **iOS can't receive in the background.** Only Apple's AirDrop may listen for transfers when the app
  isn't on screen, so SwiftDrop receives while it's open, and finishes transfers already in progress for
  ~30 s after you leave it. Sending through the Share sheet works any time.
- **"No app" on Android** is as close as Android allows: there's no screen to open, but Android
  requires a (minimised, silent) notification for any background service.
- **Discovery** uses LocalSend's multicast announcements, with an automatic subnet scan as a fallback
  for networks that block multicast (some guest/enterprise Wi-Fi). Devices must be on the same network.
  SwiftDrop doesn't create its own Wi-Fi link the way AirDrop does.
- **Windows' built-in Nearby Sharing and Android's Quick Share** use proprietary protocols. See
  [docs/NativeReceiving.md](docs/NativeReceiving.md) for the plan to add Quick Share so stock Android phones
  can receive with nothing installed.

## Build from source

| Platform | Command | Output |
|---|---|---|
| macOS | `cd macOS && ./build.sh` (or `./build.sh --install`) | `macOS/build/SwiftDrop.app` |
| iOS | `cd iOS && xcodebuild -scheme SwiftDrop -sdk iphonesimulator build` (or open in Xcode) | — |
| Android | `cd Android && ./gradlew assembleRelease` (JDK 17, Android SDK 35) | `app/build/outputs/apk/release/app-release.apk` |
| Windows | `cd Windows/SwiftDrop.Windows && dotnet publish -c Release -r win-x64 --self-contained false` | `bin/Release/…/publish/SwiftDrop.exe` |
| CLI | `cd Windows/SwiftDrop.Cli && dotnet build -c Release` | `swiftdrop.dll` |

The Windows app cross-builds on macOS/Linux with the official .NET 8 SDK (`EnableWindowsTargeting` is on).
The iOS project is generated from `iOS/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
the generated `.xcodeproj` is committed, so you don't need XcodeGen to build.

## Repository layout
```
Core/Swift/     LocalSend engine shared by macOS + iOS (HTTP/TLS server, multicast, client, sessions, avatars)
macOS/          Menu bar app + Finder Share extension (swiftc build script, no Xcode project needed)
iOS/            iPhone/iPad app + Share extension (XcodeGen spec + generated project)
Android/        Kotlin app: engine, foreground receiver, Quick Settings tile, share target, Compose UI
Windows/        SwiftDrop.Core (cross-platform engine) · SwiftDrop.Windows (tray app) · SwiftDrop.Cli (headless peer)
Tests/          fake_peer.py — minimal LocalSend peer for protocol testing
docs/           NativeReceiving.md — the plan for receiving with nothing installed (Quick Share)
```

## Tested
Every direction was tested between the Mac app, an iOS 27 simulator, an Android 15 emulator, and the Windows
engine (via the CLI). Each test sent a folder with subfolders, a 50 MB binary, a photo and a text message, and
every file arrived byte-for-byte identical (12/12 directions). The accept/decline prompts, auto-accept favourites,
folder de-duplication ("Album (2)") and HTTPS were also exercised. On the Mac, sending runs at ~950 MB/s and
receiving at ~280 MB/s over loopback, so on a real network the Wi-Fi link is the limit, not the app.
The Windows tray UI was compiled but not run on a Windows machine; its engine was tested on macOS.
