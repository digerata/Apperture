import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

final class RemoteFrameStreamServer {
    private let queue = DispatchQueue(label: "com.mikewille.Apperture.frame-server")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var readyConnectionIDs: Set<UUID> = []
    private var retryWorkItem: DispatchWorkItem?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var lastPacket: Data?
    private var wallpaperPacket: Data?
    private var windowListPacket: Data?
    private var statusHandler: ((FrameServerStatus) -> Void)?
    private var controlHandler: ((RemoteControlMessage) -> Void)?

    func start(
        statusHandler: @escaping (FrameServerStatus) -> Void,
        controlHandler: @escaping (RemoteControlMessage) -> Void
    ) {
        queue.async {
            self.statusHandler = statusHandler
            self.controlHandler = controlHandler
            guard self.listener == nil else {
                self.publishStatus()
                return
            }

            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true

                let parameters = NWParameters(tls: nil, tcp: tcpOptions)
                parameters.allowLocalEndpointReuse = true
                parameters.includePeerToPeer = true

                guard let port = NWEndpoint.Port(rawValue: RemoteFrameStreamConfiguration.tcpPort) else {
                    statusHandler(.failed("Invalid stream port."))
                    return
                }

                let listener = try NWListener(using: parameters, on: port)
                listener.service = NWListener.Service(
                    name: Self.serviceName,
                    type: RemoteFrameStreamConfiguration.bonjourType,
                    domain: RemoteFrameStreamConfiguration.bonjourDomain
                )
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }

                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                statusHandler(.failed(Self.listenerFailureMessage(for: error)))
                self.scheduleRetryIfNeeded(for: error)
            }
        }
    }

    func stop() {
        queue.async {
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.readyConnectionIDs.removeAll()
            self.lastPacket = nil
            self.wallpaperPacket = nil
            self.windowListPacket = nil
            self.statusHandler?(.offline)
        }
    }

    func publishWindowList(_ windows: [RemoteWindowSummary]) {
        queue.async {
            guard let packet = Self.makeWindowListPacket(windows) else { return }
            self.windowListPacket = packet

            for id in self.readyConnectionIDs {
                self.send(packet, to: id)
            }
        }
    }

    func publishWallpaper(_ image: CGImage) {
        queue.async {
            guard let packet = Self.makePacket(type: .wallpaper, image: image) else { return }
            self.wallpaperPacket = packet

            for id in self.readyConnectionIDs {
                self.send(packet, to: id)
            }
        }
    }

    func publish(_ image: CGImage) {
        queue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastFrameTime >= 1.0 / RemoteFrameStreamConfiguration.targetFrameRate else { return }
            self.lastFrameTime = now

            guard let packet = Self.makePacket(type: .frame, image: image) else { return }
            self.lastPacket = packet

            for id in self.readyConnectionIDs {
                self.send(packet, to: id)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, id: id)
        }
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            retryWorkItem?.cancel()
            retryWorkItem = nil
            publishStatus()
        case .waiting(let error):
            statusHandler?(.failed(Self.listenerFailureMessage(for: error)))
            scheduleRetryIfNeeded(for: error)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            statusHandler?(.failed(Self.listenerFailureMessage(for: error)))
            scheduleRetryIfNeeded(for: error)
        case .cancelled:
            listener = nil
            statusHandler?(.offline)
        default:
            break
        }
    }

    private func scheduleRetryIfNeeded(for error: Error) {
        guard Self.shouldRetryListenerFailure(error) else { return }
        guard retryWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            guard self.listener == nil,
                  let statusHandler,
                  let controlHandler else { return }
            self.start(statusHandler: statusHandler, controlHandler: controlHandler)
        }

        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) {
        switch state {
        case .ready:
            readyConnectionIDs.insert(id)
            publishStatus()
            receiveControlLength(from: id)
            if let wallpaperPacket {
                send(wallpaperPacket, to: id)
            }
            if let windowListPacket {
                send(windowListPacket, to: id)
            }
            if let lastPacket {
                send(lastPacket, to: id)
            }
        case .waiting(let error):
            closeConnection(id: id, reason: error.localizedDescription)
        case .failed(let error):
            closeConnection(id: id, reason: error.localizedDescription)
        case .cancelled:
            closeConnection(id: id)
        default:
            break
        }
    }

    private func send(_ packet: Data, to id: UUID) {
        guard let connection = connections[id] else {
            readyConnectionIDs.remove(id)
            publishStatus()
            return
        }

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.closeConnection(id: id, reason: error.localizedDescription)
        })
    }

    private func closeConnection(id: UUID, reason: String? = nil) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        readyConnectionIDs.remove(id)
        publishStatus()
    }

    private func receiveControlLength(from id: UUID) {
        guard let connection = connections[id] else { return }

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil || isComplete {
                self.closeConnection(id: id)
                return
            }

            guard let data, data.count == 4 else {
                self.receiveControlLength(from: id)
                return
            }

            let messageLength = data.reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }

            guard messageLength > 0, messageLength <= RemoteFrameStreamConfiguration.maxControlMessageBytes else {
                self.closeConnection(id: id)
                return
            }

            self.receiveControlPayload(length: Int(messageLength), from: id)
        }
    }

    private func receiveControlPayload(length: Int, from id: UUID) {
        guard let connection = connections[id] else { return }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil || isComplete {
                self.closeConnection(id: id)
                return
            }

            if let data, data.count == length,
               let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data) {
                self.controlHandler?(message)
            }

            self.receiveControlLength(from: id)
        }
    }

    private func publishStatus() {
        statusHandler?(.online(port: RemoteFrameStreamConfiguration.tcpPort, clientCount: readyConnectionIDs.count))
    }

    private static func makePacket(type: RemoteFrameStreamConfiguration.PacketType, image: CGImage) -> Data? {
        let encodedData: Data?
        switch type {
        case .frame:
            encodedData = image.hasAlpha ? makePNGData(from: image) : makeJPEGData(from: image)
        case .wallpaper:
            encodedData = makeJPEGData(from: image)
        case .windowList:
            return nil
        }

        guard let encodedData else { return nil }

        var payload = Data([type.rawValue])
        payload.append(encodedData)

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeWindowListPacket(_ windows: [RemoteWindowSummary]) -> Data? {
        guard let encodedData = try? JSONEncoder().encode(RemoteWindowListMessage(windows: windows)) else {
            return nil
        }

        var payload = Data([RemoteFrameStreamConfiguration.PacketType.windowList.rawValue])
        payload.append(encodedData)

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeJPEGData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: RemoteFrameStreamConfiguration.jpegQuality
        ] as CFDictionary

        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func makePNGData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static var serviceName: String {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return "Apperture \(hostName)"
    }

    private static func listenerFailureMessage(for error: Error) -> String {
        guard isAddressInUse(error) else {
            return error.localizedDescription
        }

        return "Port \(RemoteFrameStreamConfiguration.tcpPort) is already in use. Quit the other Apperture copy, then this host will retry automatically."
    }

    private static func shouldRetryListenerFailure(_ error: Error) -> Bool {
        isAddressInUse(error)
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError,
           case .posix(let code) = nwError {
            return code == .EADDRINUSE
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EADDRINUSE)
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}

enum FrameServerStatus: Equatable {
    case offline
    case online(port: UInt16, clientCount: Int)
    case failed(String)

    var title: String {
        switch self {
        case .offline:
            return "Remote Off"
        case .online(_, let clientCount):
            return clientCount == 0 ? "Remote Ready" : "Remote Connected"
        case .failed:
            return "Remote Failed"
        }
    }

    var detail: String {
        switch self {
        case .offline:
            return "Bonjour frame service is not running."
        case .online(let port, let clientCount):
            return clientCount == 0
                ? "Listening on port \(port). Use Connect to Mac on cellular or Tailscale."
                : "\(clientCount) iPhone connection\(clientCount == 1 ? "" : "s") on port \(port)."
        case .failed(let message):
            return message
        }
    }
}
