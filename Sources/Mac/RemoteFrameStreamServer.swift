import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

final class RemoteFrameStreamServer {
    private let queue = DispatchQueue(label: "com.mikewille.Apperture.frame-server")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
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
    private var developerActivityPacket: Data?
    private var streamGeneration: UInt64 = 0
    private var lastBackpressureKeyFrameRequestTime: CFAbsoluteTime = 0
    private var statusHandler: ((FrameServerStatus) -> Void)?
    private var controlHandler: ((RemoteControlMessage) -> Void)?
    private var diagnosticsWindowStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastDiagnosticsTime: CFAbsoluteTime = 0
    private var capturedFrameCount = 0
    private var encodedFrameCount = 0
    private var sentFrameCount = 0
    private var encodedByteCount = 0
    private var droppedFrameCount = 0
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
    private var adaptiveBitRate = RemoteFrameStreamConfiguration.videoBitRate
    private var adaptiveQuality = RemoteFrameStreamConfiguration.videoQuality
    private var adaptiveFrameRate = RemoteFrameStreamConfiguration.targetFrameRate
    private var cleanAdaptiveWindowCount = 0

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
            self.frameSendInFlightIDs.removeAll()
            self.pendingFramePackets.removeAll()
            self.connectionsNeedingKeyFrame.removeAll()
            self.lastPacket = nil
            self.videoFormatPacket = nil
            self.videoMaskPacket = nil
            self.videoMaskSize = .zero
            self.wallpaperPacket = nil
            self.windowListPacket = nil
            self.developerActivityPacket = nil
            self.streamGeneration &+= 1
            self.lastBackpressureKeyFrameRequestTime = 0
            self.resetAdaptiveStreamSettings()
            self.resetDiagnosticsWindow()
            self.videoEncoder.invalidate()
            self.statusHandler?(.offline)
        }
    }

    func resetVideoStream() {
        queue.async {
            self.streamGeneration &+= 1
            self.lastFrameTime = 0
            self.lastPacket = nil
            self.videoFormatPacket = nil
            self.videoMaskPacket = nil
            self.videoMaskSize = .zero
            self.pendingFramePackets.removeAll()
            self.connectionsNeedingKeyFrame.removeAll()
            self.lastBackpressureKeyFrameRequestTime = 0
            self.resetAdaptiveStreamSettings()
            self.resetDiagnosticsWindow()
            self.videoEncoder.invalidate()

            guard let maskPacket = Self.makeEmptyMaskPacket() else { return }
            for id in self.readyConnectionIDs {
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

    func publishDeveloperActivity(_ event: DeveloperActivityEvent) {
        queue.async {
            guard let packet = Self.makePacket(type: .developerActivity, message: event) else { return }
            self.developerActivityPacket = packet

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

    func publish(_ frame: LiveCaptureFrame, includeAlphaMask: Bool = false) {
        queue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastFrameTime >= 1.0 / self.adaptiveFrameRate else { return }
            self.lastFrameTime = now
            let generation = self.streamGeneration

            guard frame.pixelSize.width > 0, frame.pixelSize.height > 0 else { return }
            self.recordCaptureTiming(frame.timing, size: frame.pixelSize)

            if includeAlphaMask, let image = frame.image, image.hasAlpha {
                let imageSize = CGSize(width: image.width, height: image.height)
                if self.videoMaskPacket == nil || self.videoMaskSize != imageSize,
                   let maskPacket = Self.makeAlphaMaskPacket(from: image) {
                    self.videoMaskPacket = maskPacket
                    self.videoMaskSize = imageSize
                    for id in self.readyConnectionIDs {
                        self.send(maskPacket, to: id)
                    }
                }
            } else if self.videoMaskPacket != nil {
                self.videoMaskPacket = nil
                self.videoMaskSize = .zero
                if let maskPacket = Self.makeEmptyMaskPacket() {
                    for id in self.readyConnectionIDs {
                        self.send(maskPacket, to: id)
                    }
                }
            }

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
                        self.lastEncodedSize = frame.pixelSize
                        self.lastPacket = framePacket
                        for id in self.readyConnectionIDs {
                            self.sendFrame(framePacket, to: id)
                        }
                        self.publishDiagnosticsIfNeeded()
                    }
                }
            }

            if let pixelBuffer = frame.pixelBuffer {
                self.videoEncoder.encode(pixelBuffer, outputHandler: outputHandler)
            } else if let image = frame.image {
                self.videoEncoder.encode(image, outputHandler: outputHandler)
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
            if let developerActivityPacket {
                send(developerActivityPacket, to: id)
            }
            if let videoFormatPacket {
                send(videoFormatPacket, to: id)
            }
            if let videoMaskPacket {
                send(videoMaskPacket, to: id)
            }
            if let lastPacket, lastPacket.isKeyFrame {
                sendFrame(lastPacket, to: id)
            } else {
                connectionsNeedingKeyFrame.insert(id)
            }
            videoEncoder.requestKeyFrame()
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
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
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

            if let data, data.count == length,
               let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data) {
                if message.kind == .requestKeyFrame {
                    self.connectionsNeedingKeyFrame.insert(id)
                    self.requestBackpressureKeyFrameIfNeeded()
                } else {
                    self.controlHandler?(message)
                }
            }

            self.receiveControlLength(from: id)
        }
    }

    private func publishStatus() {
        statusHandler?(.online(port: RemoteFrameStreamConfiguration.tcpPort, clientCount: readyConnectionIDs.count))
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
            droppedFrames: droppedFrameCount,
            backpressureKeyFrames: backpressureKeyFrameRequestCount,
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
        droppedFrames: Int,
        backpressureKeyFrames: Int,
        encodedFPS: Double,
        sentFPS: Double
    ) {
        let sendRatio = encodedFPS > 0 ? sentFPS / encodedFPS : 1
        let isCongested = droppedFrames > 0 || backpressureKeyFrames > 0 || sendRatio < 0.82

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
        case .windowList, .videoFormat, .videoFrame, .videoMask, .streamDiagnostics, .developerActivity:
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
        guard let encodedData = try? JSONEncoder().encode(message) else {
            return nil
        }

        var payload = Data([type.rawValue])
        payload.append(encodedData)

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

        guard let roundedClipAlpha = makeRoundedClipAlpha(width: width, height: height) else {
            return nil
        }

        var maskPixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = y * bytesPerRow + x * bytesPerPixel + 3
                let maskOffset = y * bytesPerRow + x * bytesPerPixel
                let alpha = min(pixels[sourceOffset], roundedClipAlpha[y * width + x])
                maskPixels[maskOffset] = alpha
                maskPixels[maskOffset + 1] = alpha
                maskPixels[maskOffset + 2] = alpha
                maskPixels[maskOffset + 3] = alpha
            }
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

    private static func makeRoundedClipAlpha(width: Int, height: Int) -> [UInt8]? {
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let cornerRadius = min(CGFloat(width), CGFloat(height)) * 0.095
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.fillPath()
        return alpha
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
