import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

final class RemoteFrameStreamServer {
    private let queue = DispatchQueue(label: "com.mikewille.Apperture.frame-server")
    private let frameAdmissionLock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var authenticatedDevices: [UUID: PairedDevice] = [:]
    private var pendingPairingConnections: Set<UUID> = []
    private var readyConnectionIDs: Set<UUID> = []
    private var frameSendInFlightIDs: Set<UUID> = []
    private var pendingFramePackets: [UUID: PendingFramePacket] = [:]
    private var connectionsNeedingKeyFrame: Set<UUID> = []
    private var retryWorkItem: DispatchWorkItem?
    private let videoEncoder = RemoteVideoEncoder()
    private var lastFrameTime: CFAbsoluteTime = 0
    private var lastPacket: PendingFramePacket?
    private var videoFormatPacket: Data?
    private var videoMaskPacket: Data?
    private var videoMaskSize = CGSize.zero
    private var wallpaperPacket: Data?
    private var windowListPacket: Data?
    private var appIconPackets: [String: Data] = [:]
    private var clipboardPacket: Data?
    private var streamGeneration: UInt64 = 0
    private var lastBackpressureKeyFrameRequestTime: CFAbsoluteTime = 0
    private var statusHandler: ((FrameServerStatus) -> Void)?
    private var controlHandler: ((RemoteControlMessage) -> Void)?
    private var clipboardHandler: ((RemoteClipboardMessage) -> Void)?
    private var pairingRequestHandler: ((UUID, PairingRequest, String?) -> Void)?
    private var authRequestHandler: ((PairingAuthRequest, String?) -> PairedDevice?)?
    private var connectionAuthenticatedHandler: ((UUID, PairedDevice, String?) -> Void)?
    private var connectionClosedHandler: ((UUID, PairedDevice?, String?) -> Void)?
    private var diagnosticsWindowStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastDiagnosticsTime: CFAbsoluteTime = 0
    private var capturedFrameCount = 0
    private var encodedFrameCount = 0
    private var sentFrameCount = 0
    private var encodedByteCount = 0
    private var droppedFrameCount = 0
    private var congestionDroppedFrameCount = 0
    private var backpressureKeyFrameRequestCount = 0
    private var directFrameCount = 0
    private var capturePrepMilliseconds = 0.0
    private var cgImageMilliseconds = 0.0
    private var cropMilliseconds = 0.0
    private var materializeMilliseconds = 0.0
    private var pixelBufferMilliseconds = 0.0
    private var encodeMilliseconds = 0.0
    private var encoderQueueMilliseconds = 0.0
    private var lastCaptureSize = CGSize.zero
    private var lastEncodedSize = CGSize.zero
    private var nextFrameAdmissionTime: CFAbsoluteTime = 0
    private var admissionFrameRate = RemoteFrameStreamConfiguration.targetFrameRate
    private var adaptiveBitRate = RemoteFrameStreamConfiguration.videoBitRate
    private var adaptiveQuality = RemoteFrameStreamConfiguration.videoQuality
    private var adaptiveFrameRate = RemoteFrameStreamConfiguration.targetFrameRate
    private var cleanAdaptiveWindowCount = 0

    func start(
        statusHandler: @escaping (FrameServerStatus) -> Void,
        controlHandler: @escaping (RemoteControlMessage) -> Void,
        clipboardHandler: @escaping (RemoteClipboardMessage) -> Void,
        pairingRequestHandler: @escaping (UUID, PairingRequest, String?) -> Void,
        authRequestHandler: @escaping (PairingAuthRequest, String?) -> PairedDevice?,
        connectionAuthenticatedHandler: @escaping (UUID, PairedDevice, String?) -> Void,
        connectionClosedHandler: @escaping (UUID, PairedDevice?, String?) -> Void
    ) {
        queue.async {
            self.statusHandler = statusHandler
            self.controlHandler = controlHandler
            self.clipboardHandler = clipboardHandler
            self.pairingRequestHandler = pairingRequestHandler
            self.authRequestHandler = authRequestHandler
            self.connectionAuthenticatedHandler = connectionAuthenticatedHandler
            self.connectionClosedHandler = connectionClosedHandler
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
            self.authenticatedDevices.removeAll()
            self.pendingPairingConnections.removeAll()
            self.readyConnectionIDs.removeAll()
            self.frameSendInFlightIDs.removeAll()
            self.pendingFramePackets.removeAll()
            self.connectionsNeedingKeyFrame.removeAll()
            self.lastPacket = nil
            self.videoFormatPacket = nil
            self.videoMaskPacket = nil
            self.videoMaskSize = .zero
            self.wallpaperPacket = nil
            self.windowListPacket = nil
            self.clipboardPacket = nil
            self.streamGeneration &+= 1
            self.lastFrameTime = 0
            self.resetFrameAdmission()
            self.lastBackpressureKeyFrameRequestTime = 0
            self.resetAdaptiveStreamSettings()
            self.resetDiagnosticsWindow()
            self.videoEncoder.invalidate()
            self.statusHandler?(.offline)
        }
    }

    func resetVideoStream() {
        resetFrameAdmission()

        queue.async {
            self.streamGeneration &+= 1
            self.lastFrameTime = 0
            self.lastPacket = nil
            self.videoFormatPacket = nil
            self.videoMaskPacket = nil
            self.videoMaskSize = .zero
            self.pendingFramePackets.removeAll()
            self.connectionsNeedingKeyFrame.removeAll()
            self.resetFrameAdmission()
            self.lastBackpressureKeyFrameRequestTime = 0
            self.resetAdaptiveStreamSettings()
            self.resetDiagnosticsWindow()
            self.videoEncoder.invalidate()

            let resetPacket = Self.makeEmptyPacket(type: .streamReset)
            guard let maskPacket = Self.makeEmptyMaskPacket() else { return }
            for id in self.readyConnectionIDs {
                if let resetPacket {
                    self.send(resetPacket, to: id)
                }
                self.send(maskPacket, to: id)
            }
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

    func publishApplicationIcon(_ message: RemoteAppIconMessage) {
        queue.async {
            guard let packet = Self.makePacket(type: .appIcon, message: message) else { return }
            self.appIconPackets[message.appGroupID] = packet

            for id in self.readyConnectionIDs {
                self.send(packet, to: id)
            }
        }
    }

    func publishDeveloperActivity(_ event: DeveloperActivityEvent) {
        queue.async {
            guard let packet = Self.makePacket(type: .developerActivity, message: event) else { return }

            for id in self.readyConnectionIDs {
                self.send(packet, to: id)
            }
        }
    }

    func publishClipboard(_ message: RemoteClipboardMessage) {
        queue.async {
            guard let packet = Self.makePacket(type: .clipboard, message: message) else { return }
            self.clipboardPacket = packet

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

    func publish(_ image: CGImage, includeAlphaMask: Bool = false) {
        publish(
            LiveCaptureFrame(
                image: image,
                pixelBuffer: nil,
                screenFrame: .zero,
                timing: LiveCaptureFrameTiming()
            ),
            includeAlphaMask: includeAlphaMask
        )
    }

    func reserveFrameSlot() -> Bool {
        reserveFrameAdmissionSlot()
    }

    func publish(_ frame: LiveCaptureFrame, includeAlphaMask: Bool = false, frameSlotReserved: Bool = false) {
        guard frameSlotReserved || reserveFrameAdmissionSlot() else { return }

        queue.async {
            autoreleasepool {
                self.lastFrameTime = CFAbsoluteTimeGetCurrent()
                let generation = self.streamGeneration

                guard frame.pixelSize.width > 0, frame.pixelSize.height > 0 else { return }
                self.recordCaptureTiming(frame.timing, size: frame.pixelSize)

                let frameSize = frame.pixelSize
                if includeAlphaMask {
                    if self.videoMaskSize != frameSize {
                        self.videoMaskPacket = nil
                        self.videoMaskSize = frameSize
                        guard let maskPacket = Self.makeAlphaMaskPacket(from: frame) else {
                            if let emptyMaskPacket = Self.makeEmptyMaskPacket() {
                                for id in self.readyConnectionIDs {
                                    self.send(emptyMaskPacket, to: id)
                                }
                            }
                            self.encode(frame, generation: generation)
                            return
                        }

                        self.videoMaskPacket = maskPacket
                        for id in self.readyConnectionIDs {
                            self.send(maskPacket, to: id)
                        }
                    }
                } else if self.videoMaskPacket != nil || self.videoMaskSize != .zero {
                    self.videoMaskPacket = nil
                    self.videoMaskSize = .zero
                    if let maskPacket = Self.makeEmptyMaskPacket() {
                        for id in self.readyConnectionIDs {
                            self.send(maskPacket, to: id)
                        }
                    }
                }

                self.encode(frame, generation: generation)
            }
        }
    }

    private func encode(_ frame: LiveCaptureFrame, generation: UInt64) {
        let frameSize = frame.pixelSize
        let outputHandler: RemoteVideoEncoder.OutputHandler = { [weak self] output in
            guard let self else { return }
            self.queue.async {
                guard generation == self.streamGeneration else { return }

                switch output {
                case .format(let message):
                    guard let packet = Self.makePacket(type: .videoFormat, message: message) else { return }
                    self.videoFormatPacket = packet
                    for id in self.readyConnectionIDs {
                        self.send(packet, to: id)
                    }
                case .frame(let message, let timing):
                    guard let packet = Self.makeVideoFramePacket(message) else { return }
                    let framePacket = PendingFramePacket(data: packet, isKeyFrame: message.isKeyFrame)
                    self.encodedFrameCount += 1
                    self.encodedByteCount += message.data.count
                    self.pixelBufferMilliseconds += timing.pixelBufferMilliseconds
                    self.encodeMilliseconds += timing.encodeMilliseconds
                    self.encoderQueueMilliseconds += timing.queueWaitMilliseconds
                    self.lastEncodedSize = frameSize
                    self.lastPacket = framePacket
                    for id in self.readyConnectionIDs {
                        self.sendFrame(framePacket, to: id)
                    }
                    self.publishDiagnosticsIfNeeded()
                }
            }
        }

        if let pixelBuffer = frame.pixelBuffer {
            videoEncoder.encode(pixelBuffer, outputHandler: outputHandler)
        } else if let image = frame.image {
            videoEncoder.encode(image, outputHandler: outputHandler)
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
                  let controlHandler,
                  let clipboardHandler,
                  let pairingRequestHandler,
                  let authRequestHandler,
                  let connectionAuthenticatedHandler,
                  let connectionClosedHandler else { return }
            self.start(
                statusHandler: statusHandler,
                controlHandler: controlHandler,
                clipboardHandler: clipboardHandler,
                pairingRequestHandler: pairingRequestHandler,
                authRequestHandler: authRequestHandler,
                connectionAuthenticatedHandler: connectionAuthenticatedHandler,
                connectionClosedHandler: connectionClosedHandler
            )
        }

        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) {
        switch state {
        case .ready:
            publishStatus()
            receiveControlLength(from: id)
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

    func completePairing(connectionID: UUID, response: PairingResponse) {
        queue.async {
            guard let connection = self.connections[connectionID] else { return }
            guard let packet = Self.makePacket(type: .pairingResponse, message: response) else {
                self.closeConnection(id: connectionID, reason: "Pairing response could not be encoded.")
                return
            }

            connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    self?.closeConnection(id: connectionID, reason: "Pairing completed.")
                }
            })
        }
    }

    private func authorizeConnection(id: UUID, device: PairedDevice) {
        authenticatedDevices[id] = device
        readyConnectionIDs.insert(id)
        publishStatus()
        connectionAuthenticatedHandler?(id, device, remoteEndpointDescription(for: id))

        if let authStatusPacket = Self.makePacket(type: .authStatus, message: PairingAuthStatus.accepted) {
            send(authStatusPacket, to: id)
        }
        if let hostInfoPacket = Self.makePacket(type: .hostInfo, message: Self.hostInfoMessage) {
            send(hostInfoPacket, to: id)
        }
        if let wallpaperPacket {
            send(wallpaperPacket, to: id)
        }
        // HostModel republishes a fresh window list after authentication; avoid showing stale app metadata.
        if let videoFormatPacket {
            send(videoFormatPacket, to: id)
        }
        if let videoMaskPacket {
            send(videoMaskPacket, to: id)
        }
        if let clipboardPacket {
            send(clipboardPacket, to: id)
        }
        if let lastPacket, lastPacket.isKeyFrame {
            sendFrame(lastPacket, to: id)
        } else {
            connectionsNeedingKeyFrame.insert(id)
        }
        videoEncoder.requestKeyFrame()
    }

    private func send(_ packet: Data, to id: UUID, isFrame: Bool = false) {
        guard let connection = connections[id] else {
            readyConnectionIDs.remove(id)
            frameSendInFlightIDs.remove(id)
            pendingFramePackets.removeValue(forKey: id)
            connectionsNeedingKeyFrame.remove(id)
            publishStatus()
            return
        }

        if isFrame {
            frameSendInFlightIDs.insert(id)
        }

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if isFrame {
                self?.frameSendInFlightIDs.remove(id)
            }

            guard let error else { return }
            self?.closeConnection(id: id, reason: error.localizedDescription)
        })
    }

    private func sendFrame(_ packet: PendingFramePacket, to id: UUID) {
        guard connections[id] != nil else {
            readyConnectionIDs.remove(id)
            frameSendInFlightIDs.remove(id)
            pendingFramePackets.removeValue(forKey: id)
            connectionsNeedingKeyFrame.remove(id)
            publishStatus()
            return
        }

        if connectionsNeedingKeyFrame.contains(id), !packet.isKeyFrame {
            droppedFrameCount += 1
            requestBackpressureKeyFrameIfNeeded()
            return
        }

        if pendingFramePackets[id] != nil {
            droppedFrameCount += 1
            congestionDroppedFrameCount += 1
            connectionsNeedingKeyFrame.insert(id)
            requestBackpressureKeyFrameIfNeeded()
            guard packet.isKeyFrame else { return }
        }

        if packet.isKeyFrame {
            connectionsNeedingKeyFrame.remove(id)
        }

        pendingFramePackets[id] = packet
        drainFrameSend(for: id)
    }

    private func requestBackpressureKeyFrameIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBackpressureKeyFrameRequestTime >= RemoteFrameStreamConfiguration.backpressureKeyFrameRequestInterval else {
            return
        }

        lastBackpressureKeyFrameRequestTime = now
        backpressureKeyFrameRequestCount += 1
        videoEncoder.requestKeyFrame()
    }

    private func reserveFrameAdmissionSlot() -> Bool {
        frameAdmissionLock.lock()
        defer { frameAdmissionLock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        let minimumInterval = 1.0 / max(admissionFrameRate, 1)
        guard now >= nextFrameAdmissionTime else { return false }

        nextFrameAdmissionTime = now + minimumInterval
        return true
    }

    private func resetFrameAdmission() {
        frameAdmissionLock.lock()
        admissionFrameRate = RemoteFrameStreamConfiguration.targetFrameRate
        nextFrameAdmissionTime = 0
        frameAdmissionLock.unlock()
    }

    private func updateFrameAdmissionRate(_ frameRate: Double) {
        frameAdmissionLock.lock()
        admissionFrameRate = frameRate
        frameAdmissionLock.unlock()
    }

    private func drainFrameSend(for id: UUID) {
        guard !frameSendInFlightIDs.contains(id),
              let packet = pendingFramePackets.removeValue(forKey: id),
              let connection = connections[id] else {
            return
        }

        frameSendInFlightIDs.insert(id)
        sentFrameCount += 1
        connection.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }

            self.queue.async {
                self.frameSendInFlightIDs.remove(id)

                if let error {
                    self.closeConnection(id: id, reason: error.localizedDescription)
                    return
                }

                self.drainFrameSend(for: id)
            }
        })
    }

    private func closeConnection(id: UUID, reason: String? = nil) {
        let device = authenticatedDevices[id]
        connectionClosedHandler?(id, device, reason)
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        authenticatedDevices.removeValue(forKey: id)
        pendingPairingConnections.remove(id)
        readyConnectionIDs.remove(id)
        frameSendInFlightIDs.remove(id)
        pendingFramePackets.removeValue(forKey: id)
        connectionsNeedingKeyFrame.remove(id)
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

            if let data, data.count == length {
                self.handleClientPayload(data, from: id)
            }

            self.receiveControlLength(from: id)
        }
    }

    private func handleClientPayload(_ data: Data, from id: UUID) {
        if let envelope = try? JSONDecoder.apperture.decode(RemoteClientEnvelope.self, from: data) {
            handleClientEnvelope(envelope, from: id)
            return
        }

        if let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data) {
            guard authenticatedDevices[id] != nil else {
                closeConnection(id: id, reason: "Unauthenticated control message.")
                return
            }
            handleControlMessage(message, from: id)
            return
        }

        closeConnection(id: id, reason: "Invalid client message.")
    }

    private func handleClientEnvelope(_ envelope: RemoteClientEnvelope, from id: UUID) {
        switch envelope.kind {
        case .pairingRequest:
            guard let request = envelope.pairingRequest else {
                closeConnection(id: id, reason: "Invalid pairing request.")
                return
            }
            pendingPairingConnections.insert(id)
            pairingRequestHandler?(id, request, remoteEndpointDescription(for: id))
        case .authRequest:
            guard let request = envelope.authRequest,
                  PrivateNetworkClassifier.isAllowedPrivateEndpoint(remoteEndpointDescription(for: id)),
                  let device = authRequestHandler?(request, remoteEndpointDescription(for: id)) else {
                if let packet = Self.makePacket(type: .authStatus, message: PairingAuthStatus.rejected("This device is not paired with this Mac or is not on a private network.")) {
                    send(packet, to: id)
                }
                closeConnection(id: id, reason: "Authentication failed.")
                return
            }
            authorizeConnection(id: id, device: device)
        case .control:
            guard authenticatedDevices[id] != nil else {
                closeConnection(id: id, reason: "Unauthenticated control message.")
                return
            }
            guard let message = envelope.control else { return }
            handleControlMessage(message, from: id)
        case .clipboard:
            guard authenticatedDevices[id] != nil else {
                closeConnection(id: id, reason: "Unauthenticated clipboard message.")
                return
            }
            guard let message = envelope.clipboard else { return }
            clipboardHandler?(message)
        }
    }

    private func handleControlMessage(_ message: RemoteControlMessage, from id: UUID) {
        if message.kind == .requestKeyFrame {
            connectionsNeedingKeyFrame.insert(id)
            requestBackpressureKeyFrameIfNeeded()
        } else {
            controlHandler?(message)
        }
    }

    private func publishStatus() {
        let clients = readyConnectionIDs.compactMap { id -> ConnectedFrameClient? in
            guard let device = authenticatedDevices[id] else { return nil }
            return ConnectedFrameClient(
                id: id,
                displayName: device.displayName,
                symbolName: device.symbolName
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        statusHandler?(.online(port: RemoteFrameStreamConfiguration.tcpPort, clients: clients))
    }

    private func remoteEndpointDescription(for id: UUID) -> String? {
        guard let endpoint = connections[id]?.endpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type)\(domain)"
        case .url(let url):
            return url.absoluteString
        case .unix(let path):
            return path
        case .opaque:
            return nil
        @unknown default:
            return nil
        }
    }

    private func recordCaptureTiming(_ timing: LiveCaptureFrameTiming, size: CGSize) {
        capturedFrameCount += 1
        lastCaptureSize = size
        capturePrepMilliseconds += timing.totalMilliseconds
        cgImageMilliseconds += timing.cgImageMilliseconds
        cropMilliseconds += timing.cropMilliseconds
        materializeMilliseconds += timing.materializeMilliseconds
        if timing.usesDirectPixelBuffer {
            directFrameCount += 1
        }
    }

    private func publishDiagnosticsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDiagnosticsTime >= 1 else { return }

        let duration = max(now - diagnosticsWindowStartTime, 0.001)
        let captureCount = max(capturedFrameCount, 1)
        let encodeCount = max(encodedFrameCount, 1)
        let encodedFPS = Double(encodedFrameCount) / duration
        let sentFPS = Double(sentFrameCount) / duration
        adaptStreamIfNeeded(
            congestionDroppedFrames: congestionDroppedFrameCount,
            encodedFPS: encodedFPS,
            sentFPS: sentFPS
        )
        let message = RemoteStreamDiagnosticsMessage(
            captureWidth: Int(lastCaptureSize.width),
            captureHeight: Int(lastCaptureSize.height),
            encodedWidth: Int(lastEncodedSize.width),
            encodedHeight: Int(lastEncodedSize.height),
            captureFPS: Double(capturedFrameCount) / duration,
            encodedFPS: encodedFPS,
            sentFPS: sentFPS,
            bitrateMbps: Double(encodedByteCount * 8) / duration / 1_000_000,
            configuredBitrateMbps: Double(adaptiveBitRate) / 1_000_000,
            targetFPS: adaptiveFrameRate,
            videoQuality: adaptiveQuality,
            droppedFrames: droppedFrameCount,
            backpressureKeyFrames: backpressureKeyFrameRequestCount,
            keyFrameInterval: RemoteFrameStreamConfiguration.videoKeyFrameInterval,
            codec: "H.264",
            capturePrepMS: capturePrepMilliseconds / Double(captureCount),
            cgImageMS: cgImageMilliseconds / Double(captureCount),
            cropMS: cropMilliseconds / Double(captureCount),
            materializeMS: materializeMilliseconds / Double(captureCount),
            pixelBufferMS: pixelBufferMilliseconds / Double(encodeCount),
            encodeMS: encodeMilliseconds / Double(encodeCount),
            encoderQueueMS: encoderQueueMilliseconds / Double(encodeCount),
            directFramePercent: Double(directFrameCount) / Double(captureCount) * 100
        )

        guard let packet = Self.makePacket(type: .streamDiagnostics, message: message) else { return }
        for id in readyConnectionIDs {
            send(packet, to: id)
        }

        lastDiagnosticsTime = now
        diagnosticsWindowStartTime = now
        capturedFrameCount = 0
        encodedFrameCount = 0
        sentFrameCount = 0
        encodedByteCount = 0
        droppedFrameCount = 0
        congestionDroppedFrameCount = 0
        backpressureKeyFrameRequestCount = 0
        directFrameCount = 0
        capturePrepMilliseconds = 0
        cgImageMilliseconds = 0
        cropMilliseconds = 0
        materializeMilliseconds = 0
        pixelBufferMilliseconds = 0
        encodeMilliseconds = 0
        encoderQueueMilliseconds = 0
    }

    private func adaptStreamIfNeeded(
        congestionDroppedFrames: Int,
        encodedFPS: Double,
        sentFPS: Double
    ) {
        let sendRatio = encodedFPS > 0 ? sentFPS / encodedFPS : 1
        let isCongested = congestionDroppedFrames > 0 || sendRatio < 0.82

        if isCongested {
            cleanAdaptiveWindowCount = 0
            let nextBitRate = max(
                RemoteFrameStreamConfiguration.minimumAdaptiveVideoBitRate,
                Int(Double(adaptiveBitRate) * 0.72)
            )
            let nextQuality = max(
                RemoteFrameStreamConfiguration.minimumAdaptiveVideoQuality,
                adaptiveQuality - 0.06
            )
            let nextFrameRate = max(
                RemoteFrameStreamConfiguration.minimumAdaptiveFrameRate,
                floor(adaptiveFrameRate * 0.82)
            )
            applyAdaptiveStreamSettings(bitRate: nextBitRate, quality: nextQuality, frameRate: nextFrameRate)
            return
        }

        cleanAdaptiveWindowCount += 1
        guard cleanAdaptiveWindowCount >= 4 else { return }
        cleanAdaptiveWindowCount = 0

        let nextBitRate = min(
            RemoteFrameStreamConfiguration.maximumAdaptiveVideoBitRate,
            Int(Double(adaptiveBitRate) * 1.14)
        )
        let nextQuality = min(
            RemoteFrameStreamConfiguration.maximumAdaptiveVideoQuality,
            adaptiveQuality + 0.025
        )
        let nextFrameRate = min(
            RemoteFrameStreamConfiguration.maximumAdaptiveFrameRate,
            adaptiveFrameRate + 2
        )
        applyAdaptiveStreamSettings(bitRate: nextBitRate, quality: nextQuality, frameRate: nextFrameRate)
    }

    private func resetAdaptiveStreamSettings() {
        cleanAdaptiveWindowCount = 0
        applyAdaptiveStreamSettings(
            bitRate: RemoteFrameStreamConfiguration.videoBitRate,
            quality: RemoteFrameStreamConfiguration.videoQuality,
            frameRate: RemoteFrameStreamConfiguration.targetFrameRate
        )
    }

    private func applyAdaptiveStreamSettings(bitRate: Int, quality: Double, frameRate: Double) {
        let clampedBitRate = min(
            max(bitRate, RemoteFrameStreamConfiguration.minimumAdaptiveVideoBitRate),
            RemoteFrameStreamConfiguration.maximumAdaptiveVideoBitRate
        )
        let clampedQuality = min(
            max(quality, RemoteFrameStreamConfiguration.minimumAdaptiveVideoQuality),
            RemoteFrameStreamConfiguration.maximumAdaptiveVideoQuality
        )
        let clampedFrameRate = min(
            max(frameRate, RemoteFrameStreamConfiguration.minimumAdaptiveFrameRate),
            RemoteFrameStreamConfiguration.maximumAdaptiveFrameRate
        )

        guard clampedBitRate != adaptiveBitRate ||
              clampedQuality != adaptiveQuality ||
              clampedFrameRate != adaptiveFrameRate else {
            return
        }

        adaptiveBitRate = clampedBitRate
        adaptiveQuality = clampedQuality
        adaptiveFrameRate = clampedFrameRate
        updateFrameAdmissionRate(clampedFrameRate)
        videoEncoder.updateAdaptiveSettings(
            bitRate: clampedBitRate,
            quality: clampedQuality,
            frameRate: clampedFrameRate
        )
    }

    private func resetDiagnosticsWindow() {
        diagnosticsWindowStartTime = CFAbsoluteTimeGetCurrent()
        lastDiagnosticsTime = 0
        capturedFrameCount = 0
        encodedFrameCount = 0
        sentFrameCount = 0
        encodedByteCount = 0
        droppedFrameCount = 0
        congestionDroppedFrameCount = 0
        backpressureKeyFrameRequestCount = 0
        directFrameCount = 0
        capturePrepMilliseconds = 0
        cgImageMilliseconds = 0
        cropMilliseconds = 0
        materializeMilliseconds = 0
        pixelBufferMilliseconds = 0
        encodeMilliseconds = 0
        encoderQueueMilliseconds = 0
        lastCaptureSize = .zero
        lastEncodedSize = .zero
    }

    private static func makePacket(type: RemoteFrameStreamConfiguration.PacketType, image: CGImage) -> Data? {
        let encodedData: Data?
        switch type {
        case .frame:
            encodedData = image.hasAlpha ? makePNGData(from: image) : makeJPEGData(from: image)
        case .wallpaper:
            encodedData = makeJPEGData(from: image)
        case .windowList, .videoFormat, .videoFrame, .videoMask, .streamDiagnostics, .developerActivity, .streamReset, .hostInfo, .appIcon, .pairingResponse, .authStatus, .clipboard:
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

    private static func makePacket<T: Encodable>(type: RemoteFrameStreamConfiguration.PacketType, message: T) -> Data? {
        let encodedData: Data?
        switch type {
        case .pairingResponse, .authStatus:
            encodedData = try? JSONEncoder.apperture.encode(message)
        case .frame, .wallpaper, .windowList, .videoFormat, .videoFrame, .videoMask, .streamDiagnostics, .developerActivity, .streamReset, .hostInfo, .appIcon, .clipboard:
            encodedData = try? JSONEncoder().encode(message)
        }

        guard let encodedData else {
            return nil
        }

        var payload = Data([type.rawValue])
        payload.append(encodedData)

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeEmptyPacket(type: RemoteFrameStreamConfiguration.PacketType) -> Data? {
        guard type == .streamReset else { return nil }

        let payload = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeVideoFramePacket(_ message: RemoteVideoFrameMessage) -> Data? {
        var payload = Data([RemoteFrameStreamConfiguration.PacketType.videoFrame.rawValue])
        payload.append(message.binaryPayload())

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeAlphaMaskPacket(from frame: LiveCaptureFrame) -> Data? {
        if let image = frame.image, image.hasAlpha {
            return makeAlphaMaskPacket(from: image)
        }

        if let pixelBuffer = frame.pixelBuffer {
            return makeAlphaMaskPacket(from: pixelBuffer)
        }

        return nil
    }

    private static func makeAlphaMaskPacket(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var maskPixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        var hasTransparentPixels = false
        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = y * bytesPerRow + x * bytesPerPixel + 3
                let maskOffset = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixels[sourceOffset]
                hasTransparentPixels = hasTransparentPixels || alpha < 255
                maskPixels[maskOffset] = alpha
                maskPixels[maskOffset + 1] = alpha
                maskPixels[maskOffset + 2] = alpha
                maskPixels[maskOffset + 3] = alpha
            }
        }

        return makeAlphaMaskPacket(
            fromMaskPixels: &maskPixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            hasTransparentPixels: hasTransparentPixels
        )
    }

    private static func makeAlphaMaskPacket(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerPixel = 4
        let maskBytesPerRow = width * bytesPerPixel
        let sourceBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var maskPixels = [UInt8](repeating: 0, count: height * maskBytesPerRow)
        var hasTransparentPixels = false

        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = y * sourceBytesPerRow + x * bytesPerPixel + 3
                let maskOffset = y * maskBytesPerRow + x * bytesPerPixel
                let alpha = sourceBytes[sourceOffset]
                hasTransparentPixels = hasTransparentPixels || alpha < 255
                maskPixels[maskOffset] = alpha
                maskPixels[maskOffset + 1] = alpha
                maskPixels[maskOffset + 2] = alpha
                maskPixels[maskOffset + 3] = alpha
            }
        }

        return makeAlphaMaskPacket(
            fromMaskPixels: &maskPixels,
            width: width,
            height: height,
            bytesPerRow: maskBytesPerRow,
            hasTransparentPixels: hasTransparentPixels
        )
    }

    private static func makeAlphaMaskPacket(
        fromMaskPixels maskPixels: inout [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        hasTransparentPixels: Bool
    ) -> Data? {
        guard hasTransparentPixels else {
            return nil
        }

        guard let maskContext = CGContext(
            data: &maskPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let maskImage = maskContext.makeImage(),
              let maskData = makePNGData(from: maskImage) else {
            return nil
        }

        var payload = Data([RemoteFrameStreamConfiguration.PacketType.videoMask.rawValue])
        payload.append(maskData)

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        return packet
    }

    private static func makeEmptyMaskPacket() -> Data? {
        let payload = Data([RemoteFrameStreamConfiguration.PacketType.videoMask.rawValue])
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

    private static var hostInfoMessage: RemoteHostInfoMessage {
        let displayName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return RemoteHostInfoMessage(
            displayName: displayName,
            hostName: ProcessInfo.processInfo.hostName,
            modelIdentifier: hardwareModelIdentifier(),
            symbolName: "macbook"
        )
    }

    private static func hardwareModelIdentifier() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
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

private struct PendingFramePacket {
    var data: Data
    var isKeyFrame: Bool
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

struct ConnectedFrameClient: Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var symbolName: String
}

enum FrameServerStatus: Equatable {
    case offline
    case online(port: UInt16, clients: [ConnectedFrameClient])
    case failed(String)

    var connectedClients: [ConnectedFrameClient] {
        switch self {
        case .online(_, let clients):
            return clients
        case .offline, .failed:
            return []
        }
    }

    var clientCount: Int {
        connectedClients.count
    }

    var title: String {
        switch self {
        case .offline:
            return "Remote Off"
        case .online(_, let clients):
            return clients.isEmpty ? "Remote Ready" : "Remote Connected"
        case .failed:
            return "Remote Failed"
        }
    }

    var detail: String {
        switch self {
        case .offline:
            return "Bonjour frame service is not running."
        case .online(let port, let clients):
            return clients.isEmpty
                ? "Listening on port \(port). Use Connect to Mac on cellular or Tailscale."
                : "\(clients.count) iPhone connection\(clients.count == 1 ? "" : "s") on port \(port)."
        case .failed(let message):
            return message
        }
    }
}
