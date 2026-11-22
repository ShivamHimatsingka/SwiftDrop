import Foundation

/// Loopback-only API used by the Finder Share Extension.
final class ControlServer: @unchecked Sendable {
    private var server: HTTPServer?

    func start() {
        let s = HTTPServer { req in await ControlServer.route(req) }
        s.onFailure = { msg in NSLog("SwiftDrop control server: \(msg)") }
        do { try s.start(port: ControlAPI.port, tlsIdentity: nil, loopbackOnly: true) }
        catch { NSLog("SwiftDrop control server failed: \(error)") }
        server = s
    }

    private static func route(_ req: HTTPRequest) async -> HTTPResponse {
        guard req.remoteHost == "127.0.0.1" || req.remoteHost == "::1" else { return .forbidden }
        switch (req.method, req.path) {
        case ("GET", "/devices"):
            let deep = req.query["deep"] == "1"
            let devices: [ControlDevice] = await MainActor.run {
                let m = AppModel.shared
                m.sendingUIDidAppear(deep: deep)
                return m.peers.map {
                    ControlDevice(id: $0.id, alias: $0.alias, deviceType: $0.deviceType,
                                  deviceModel: $0.deviceModel, isFavorite: m.isFavorite($0.id))
                }
            }
            return .json(devices)

        case ("POST", "/stage"):
            let name = req.query["name"] ?? "Item"
            let dest = AppPaths.newStageFile(named: name)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: dest) else { return .text("stage failed", status: 500) }
            do {
                try await req.streamBody { try fh.write(contentsOf: $0) }
                try fh.close()
            } catch { return .text("stage failed", status: 500) }
            return .json(ControlStageResponse(path: dest.path))

        case ("POST", "/send"):
            guard let body = try? await req.readBody(limit: 32 << 20),
                  let r = try? JSONDecoder().decode(ControlSendRequest.self, from: body) else { return .badRequest }
            let payload = OutgoingPayload(fileURLs: r.paths.map { URL(fileURLWithPath: $0) }, texts: r.texts)
            let id = await MainActor.run { AppModel.shared.send(payload, to: r.deviceId) }
            guard let id else { return .notFound }
            return .json(ControlSendResponse(transferId: id))

        case ("GET", "/transfer"):
            guard let id = req.query["id"] else { return .badRequest }
            let status: ControlTransferStatus? = await MainActor.run {
                AppModel.shared.transferStatus(id).map {
                    ControlTransferStatus(id: $0.id, deviceId: $0.peerID, phase: $0.phase,
                                          progress: $0.progress, message: $0.message)
                }
            }
            return status.map { .json($0) } ?? .notFound

        case ("POST", "/cancel"):
            if let id = req.query["id"] { await MainActor.run { AppModel.shared.cancelTransfer(id) } }
            return .ok

        default:
            return .notFound
        }
    }
}
