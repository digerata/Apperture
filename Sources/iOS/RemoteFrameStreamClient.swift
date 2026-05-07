import Foundation
import Combine
import CoreMedia
import Network
import UIKit

@MainActor
final class RemoteFrameStreamClient: ObservableObject {
    @Published private(set) var state: RemoteFrameStreamState = .idle
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var videoFrameSize: CGSize?
    @Published private(set) var latestFrameMask: UIImage?
    @Published private(set) var wallpaper: UIImage?
    @Published private(set) var windows: [RemoteWindowSummary] = []
    @Published private(set) var hosts: [RemoteHostSummary] = []
    @Published private(set) var manualEndpointDescription: String?
    @Published private(set) var diagnostics = RemoteConnectionDiagnostics()
    @Published private(set) var streamDiagnostics: RemoteStreamDiagnosticsMessage?
    @Published private(set) var developerActivity = DeveloperActivityState(eventDirectoryPath: "")
    let videoSampleBuffers = PassthroughSubject<CMSampleBuffer, Never>()

    private let queue = DispatchQueue(label: "com.mikewille.Apperture.frame-client")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var browseResults: Set<NWBrowser.Result> = []
    private var candidates: [StreamEndpointCandidate] = []
    private var nextCandidateIndex = 0
    private var retryWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?
    private var connectedHostName: String?
    private var activeCandidateID: String?
    private var savedManualEndpoints: [ManualStreamEndpoint] = []
    private var appIconCache: [String: Data] = [:]
    private let videoDecoder = RemoteVideoDecoder()
    private var nextSequenceNumber: UInt64 = 0
    private var lastKeyFrameRequestTime: CFAbsoluteTime = 0
    private var requiresVideoKeyFrame = false
    private var isAwaitingStreamResetAfterSelection = false
    private var streamDecodeGeneration: UInt64 = 0

    init() {
        savedManualEndpoints = Self.loadSavedManualEndpoints()
        appIconCache = Self.loadAppIconCache()
        if let endpoint = savedManualEndpoints.first {
            manualEndpointDescription = endpoint.displayName
            updateDiagnostics { diagnostics in
                diagnostics.manualEndpoint = endpoint.displayName
            }
        }
    }

    func start() {
        guard browser == nil else { return }
        state = .searching
        recordDiagnosticEvent("Starting Bonjour browser for \(RemoteFrameStreamConfiguration.bonjourType).")
        rebuildCandidates(from: [])

        let browser = NWBrowser(
            for: .bonjour(type: RemoteFrameStreamConfiguration.bonjourType, domain: nil),
            using: Self.discoveryParameters()
        )

        browser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }

        self.browser = browser
        browser.start(queue: queue)
        connectToNextCandidate()
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        browser?.cancel()
        browser = nil
        browseResults = []
        connection?.cancel()
        connection = nil
        candidates = []
        nextCandidateIndex = 0
        connectedHostName = nil
        activeCandidateID = nil
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        streamDiagnostics = nil
        developerActivity = DeveloperActivityState(eventDirectoryPath: "")
        nextSequenceNumber = 0
        lastKeyFrameRequestTime = 0
        requiresVideoKeyFrame = false
        isAwaitingStreamResetAfterSelection = false
        streamDecodeGeneration += 1
        videoDecoder.reset()
        rebuildCandidates(from: [])
        state = .idle
        updateDiagnostics { diagnostics in
            diagnostics.browserState = "Stopped"
            diagnostics.discoveredServices = []
            diagnostics.candidates = []
            diagnostics.activeCandidate = nil
        }
        recordDiagnosticEvent("Stopped stream client.")
    }

    func restart() {
        stop()
        start()
    }

    func send(_ message: RemoteControlMessage) {
        guard let connection else { return }
        guard let payload = try? JSONEncoder().encode(message) else { return }
        guard payload.count <= RemoteFrameStreamConfiguration.maxControlMessageBytes else { return }

        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(payload)

        queue.async { [weak self, weak connection] in
            guard let connection else { return }
            connection.send(content: packet, completion: .contentProcessed { error in
                guard let error else { return }
                Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection else { return }
                    self.handleConnectionFailure(error.localizedDescription)
                }
            })
        }
    }

    func requestKeyFrameIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastKeyFrameRequestTime >= RemoteFrameStreamConfiguration.backpressureKeyFrameRequestInterval else {
            return
        }

        lastKeyFrameRequestTime = now
        requiresVideoKeyFrame = true
        nextSequenceNumber += 1
        send(RemoteControlMessage(requestKeyFrameWithSequenceNumber: nextSequenceNumber))
    }

    func clearCurrentFrame() {
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        streamDiagnostics = nil
        videoDecoder.reset()
    }

    func prepareForStreamSelection() {
        isAwaitingStreamResetAfterSelection = true
        streamDecodeGeneration += 1
        clearCurrentFrame()
    }

    @discardableResult
    func connectManually(to input: String) -> String? {
        guard let endpoint = ManualStreamEndpoint(input: input) else {
            return "Enter a Mac hostname, MagicDNS name, or Tailscale IP."
        }

        saveManualEndpoint(endpoint)
        manualEndpointDescription = endpoint.displayName
        updateDiagnostics { diagnostics in
            diagnostics.manualEndpoint = endpoint.displayName
        }
        recordDiagnosticEvent("Manual endpoint set to \(endpoint.displayName).")

        connection?.cancel()
        connection = nil
        connectedHostName = nil
        activeCandidateID = nil
        streamDecodeGeneration += 1
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
        if let index = candidates.firstIndex(where: { $0.id == endpoint.id }) {
            nextCandidateIndex = index
        }

        if browser == nil {
            start()
        } else {
            connectToNextCandidate()
        }

        return nil
    }

    func forgetManualEndpoint() {
        guard !savedManualEndpoints.isEmpty else { return }

        savedManualEndpoints = []
        manualEndpointDescription = nil
        Self.storeSavedManualEndpoints([])
        updateDiagnostics { diagnostics in
            diagnostics.manualEndpoint = nil
        }
        recordDiagnosticEvent("Saved direct hosts removed.")

        connection?.cancel()
        connection = nil
        connectedHostName = nil
        activeCandidateID = nil
        streamDecodeGeneration += 1
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
        connectToNextCandidate()
    }

    func connect(toHostID hostID: RemoteHostSummary.ID) {
        guard let index = candidates.firstIndex(where: { $0.id == hostID }) else {
            recordDiagnosticEvent("Host selection ignored; candidate is unavailable.")
            return
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection?.cancel()
        connection = nil
        connectedHostName = nil
        activeCandidateID = nil
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        streamDiagnostics = nil
        isAwaitingStreamResetAfterSelection = false
        streamDecodeGeneration += 1
        videoDecoder.reset()
        nextCandidateIndex = index
        connectToNextCandidate()
    }

    var diagnosticsReport: String {
        diagnostics.report(state: state)
    }

    private nonisolated func handleBrowserState(_ browserState: NWBrowser.State) {
        switch browserState {
        case .failed(let error):
            Task { @MainActor in
                self.updateDiagnostics { diagnostics in
                    diagnostics.browserState = "Failed: \(error.localizedDescription)"
                    diagnostics.lastError = error.localizedDescription
                }
                self.recordDiagnosticEvent("Bonjour browser failed: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
        case .ready:
            Task { @MainActor in
                self.updateDiagnostics { diagnostics in
                    diagnostics.browserState = "Ready"
                }
                self.recordDiagnosticEvent("Bonjour browser ready.")
                if self.connection == nil {
                    self.state = .searching
                }
            }
        case .waiting(let error):
            Task { @MainActor in
                self.updateDiagnostics { diagnostics in
                    diagnostics.browserState = "Waiting: \(error.localizedDescription)"
                    diagnostics.lastError = error.localizedDescription
                }
                self.recordDiagnosticEvent("Bonjour browser waiting: \(error.localizedDescription)")
            }
        case .cancelled:
            Task { @MainActor in
                self.updateDiagnostics { diagnostics in
                    diagnostics.browserState = "Cancelled"
                }
            }
        default:
            break
        }
    }

    private nonisolated func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        Task { @MainActor in
            self.browseResults = results
            self.rebuildCandidates(from: results)
            self.updateDiagnostics { diagnostics in
                diagnostics.discoveredServices = results
                    .map { String(describing: $0.endpoint) }
                    .sorted()
            }
            self.recordDiagnosticEvent("Bonjour results changed: \(results.count) service\(results.count == 1 ? "" : "s").")
            self.connectToNextCandidate()
        }
    }

    private func rebuildCandidates(from results: Set<NWBrowser.Result>) {
        var updatedCandidates: [StreamEndpointCandidate] = []

        #if targetEnvironment(simulator)
        if let port = NWEndpoint.Port(rawValue: RemoteFrameStreamConfiguration.tcpPort) {
            updatedCandidates.append(
                StreamEndpointCandidate(
                    id: "simulator-loopback",
                    name: "Mac localhost",
                    endpoint: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: port)
                )
            )
        }
        #endif

        updatedCandidates.append(
            contentsOf: savedManualEndpoints.map { endpoint in
                StreamEndpointCandidate(
                    id: endpoint.id,
                    name: endpoint.displayName,
                    endpoint: endpoint.endpoint,
                    detail: endpoint.addressDescription,
                    isSaved: true
                )
            }
        )

        updatedCandidates.append(
            contentsOf: results.map { result in
                StreamEndpointCandidate(endpoint: result.endpoint)
            }
        )

        updatedCandidates = Array(
            Dictionary(grouping: updatedCandidates, by: \.id)
                .compactMap { _, candidates in candidates.first }
        )
        .sorted { lhs, rhs in
            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.endpointDescription.localizedCaseInsensitiveCompare(rhs.endpointDescription) == .orderedAscending
        }

        guard updatedCandidates != candidates else { return }
        candidates = updatedCandidates
        updateHostSummaries()
        updateDiagnostics { diagnostics in
            diagnostics.candidates = updatedCandidates.map(\.diagnosticDescription)
        }
        if nextCandidateIndex >= candidates.count {
            nextCandidateIndex = 0
        }
    }

    private func saveManualEndpoint(_ endpoint: ManualStreamEndpoint) {
        savedManualEndpoints.removeAll { $0.id == endpoint.id }
        savedManualEndpoints.append(endpoint)
        savedManualEndpoints.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        Self.storeSavedManualEndpoints(savedManualEndpoints)
    }

    private static func loadSavedManualEndpoints() -> [ManualStreamEndpoint] {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: savedManualEndpointsDefaultsKey),
           let endpoints = try? decoder.decode([ManualStreamEndpoint].self, from: data) {
            return endpoints.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        if let legacyEndpointValue = UserDefaults.standard.string(forKey: manualEndpointDefaultsKey),
           let endpoint = ManualStreamEndpoint(input: legacyEndpointValue) {
            storeSavedManualEndpoints([endpoint])
            UserDefaults.standard.removeObject(forKey: manualEndpointDefaultsKey)
            return [endpoint]
        }

        return []
    }

    private static func storeSavedManualEndpoints(_ endpoints: [ManualStreamEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: savedManualEndpointsDefaultsKey)
    }

    private static func loadAppIconCache() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: appIconCacheDefaultsKey),
              let cache = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return cache
    }

    private static func storeAppIconCache(_ cache: [String: Data]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: appIconCacheDefaultsKey)
    }

    private func connectToNextCandidate() {
        guard connection == nil else { return }

        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard !candidates.isEmpty else {
            state = .searching
            return
        }

        let candidate = candidates[nextCandidateIndex % candidates.count]
        nextCandidateIndex = (nextCandidateIndex + 1) % candidates.count
        connect(to: candidate)
    }

    private func connect(to candidate: StreamEndpointCandidate) {
        connectedHostName = candidate.name
        activeCandidateID = candidate.id
        updateHostSummaries()
        state = .connecting(candidate.name)
        updateDiagnostics { diagnostics in
            diagnostics.activeCandidate = candidate.diagnosticDescription
            diagnostics.lastError = nil
        }
        recordDiagnosticEvent("Connecting to \(candidate.diagnosticDescription).")

        let connection = NWConnection(to: candidate.endpoint, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            self?.handleConnectionState(state, for: connection)
        }

        connection.start(queue: queue)
        scheduleTimeout(for: connection, candidate: candidate)
    }

    private nonisolated func handleConnectionState(_ connectionState: NWConnection.State, for connection: NWConnection?) {
        switch connectionState {
        case .ready:
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                let hostName = self.connectedHostName ?? "Mac"
                self.state = .connected(hostName)
                self.recordDiagnosticEvent("Connection ready: \(hostName).")
                self.receiveLength()
            }
        case .waiting(let error):
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.handleConnectionFailure(error.localizedDescription)
            }
        case .failed(let error):
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.handleConnectionFailure(error.localizedDescription)
            }
        case .cancelled:
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.handleConnectionFailure("Connection cancelled.")
            }
        default:
            break
        }
    }

    private func receiveLength() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.handleReceiveFailure(error.localizedDescription)
                    return
                }

                guard let data, data.count == 4 else {
                    if isComplete {
                        self.handleReceiveFailure("The Mac host closed the stream.")
                    } else {
                        self.receiveLength()
                    }
                    return
                }

                let frameLength = data.reduce(UInt32(0)) { partial, byte in
                    (partial << 8) | UInt32(byte)
                }

                guard frameLength > 0, frameLength < RemoteFrameStreamConfiguration.maxFrameBytes else {
                    self.handleReceiveFailure("Invalid frame size.")
                    return
                }

                self.receiveFrame(length: Int(frameLength))
            }
        }
    }

    private func receiveFrame(length: Int) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.handleReceiveFailure(error.localizedDescription)
                    return
                }

                guard let data, data.count == length else {
                    if isComplete {
                        self.handleReceiveFailure("The Mac host closed the stream.")
                    } else {
                        self.receiveLength()
                    }
                    return
                }

                self.handlePacket(data)
                self.receiveLength()
            }
        }
    }

    private func handlePacket(_ data: Data) {
        guard let firstByte = data.first,
              let type = RemoteFrameStreamConfiguration.PacketType(rawValue: firstByte) else {
            guard !isAwaitingStreamResetAfterSelection else { return }
            handleLegacyFrame(data)
            return
        }

        let imageData = data.dropFirst()

        guard !isAwaitingStreamResetAfterSelection || type.allowsDuringStreamSelectionResetWait else {
            return
        }

        switch type {
        case .frame:
            guard let image = UIImage(data: Data(imageData)) else { return }
            let hostName = connectedHostName ?? "Mac"
            state = .live(hostName)
            videoFrameSize = nil
            latestFrame = image
        case .wallpaper:
            guard let image = UIImage(data: Data(imageData)) else { return }
            wallpaper = image
        case .windowList:
            guard let message = try? JSONDecoder().decode(RemoteWindowListMessage.self, from: Data(imageData)) else {
                return
            }
            windows = message.windows.map { window in
                var updatedWindow = window
                if updatedWindow.appIconPNGData == nil {
                    updatedWindow.appIconPNGData = appIconCache[updatedWindow.appGroupID]
                }
                return updatedWindow
            }
        case .appIcon:
            guard let message = try? JSONDecoder().decode(RemoteAppIconMessage.self, from: Data(imageData)) else {
                return
            }
            appIconCache[message.appGroupID] = message.pngData
            Self.storeAppIconCache(appIconCache)
            windows = windows.map { window in
                guard window.appGroupID == message.appGroupID else { return window }
                var updatedWindow = window
                updatedWindow.appIconPNGData = message.pngData
                return updatedWindow
            }
        case .videoFormat:
            guard let message = try? JSONDecoder().decode(RemoteVideoFormatMessage.self, from: Data(imageData)) else {
                return
            }
            videoFrameSize = CGSize(width: CGFloat(message.width), height: CGFloat(message.height))
            requiresVideoKeyFrame = true
            videoDecoder.configure(message)
        case .videoFrame:
            guard let message = RemoteVideoFrameMessage.decodePayload(Data(imageData)) else {
                return
            }
            if requiresVideoKeyFrame {
                guard message.isKeyFrame else { return }
                requiresVideoKeyFrame = false
            }
            let decodeGeneration = streamDecodeGeneration
            videoDecoder.decode(message) { [weak self] sampleBuffer, size in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.streamDecodeGeneration == decodeGeneration,
                          !self.isAwaitingStreamResetAfterSelection else {
                        return
                    }
                    let hostName = self.connectedHostName ?? "Mac"
                    if size.width > 0, size.height > 0 {
                        self.videoFrameSize = size
                    }
                    self.state = .live(hostName)
                    self.videoSampleBuffers.send(sampleBuffer)
                }
            }
        case .videoMask:
            latestFrameMask = imageData.isEmpty ? nil : UIImage(data: Data(imageData))
        case .streamDiagnostics:
            guard let message = try? JSONDecoder().decode(RemoteStreamDiagnosticsMessage.self, from: Data(imageData)) else {
                return
            }
            streamDiagnostics = message
        case .developerActivity:
            guard let event = try? JSONDecoder().decode(DeveloperActivityEvent.self, from: Data(imageData)) else {
                return
            }
            developerActivity.apply(event)
        case .hostInfo:
            guard let message = try? JSONDecoder().decode(RemoteHostInfoMessage.self, from: Data(imageData)) else {
                return
            }
            applyHostInfo(message)
        case .streamReset:
            isAwaitingStreamResetAfterSelection = false
            streamDecodeGeneration += 1
            clearCurrentFrame()
            state = .connected(connectedHostName ?? "Mac")
            recordDiagnosticEvent("Remote stream reset.")
        }
    }

    private func handleLegacyFrame(_ data: Data) {
        guard let image = UIImage(data: data) else { return }

        let hostName = connectedHostName ?? "Mac"
        state = .live(hostName)
        videoFrameSize = nil
        latestFrame = image
    }

    private func handleReceiveFailure(_ message: String) {
        handleConnectionFailure(message)
    }

    private func handleConnectionFailure(_ message: String) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        streamDiagnostics = nil
        developerActivity = DeveloperActivityState(eventDirectoryPath: "")
        isAwaitingStreamResetAfterSelection = false
        streamDecodeGeneration += 1
        videoDecoder.reset()
        connection?.cancel()
        connection = nil
        connectedHostName = nil
        activeCandidateID = nil
        updateHostSummaries()
        updateDiagnostics { diagnostics in
            diagnostics.lastError = message
            diagnostics.activeCandidate = nil
        }
        recordDiagnosticEvent("Connection failed: \(message)")

        guard browser != nil else {
            state = .failed(message)
            return
        }

        state = candidates.isEmpty || Self.isTransientDiscoveryResolutionFailure(message)
            ? .searching
            : .failed(message)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.connectToNextCandidate()
            }
        }

        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    private func scheduleTimeout(for connection: NWConnection, candidate: StreamEndpointCandidate) {
        timeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.handleConnectionFailure("Timed out connecting to \(candidate.name).")
            }
        }

        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }

    private func updateDiagnostics(_ update: (inout RemoteConnectionDiagnostics) -> Void) {
        var nextDiagnostics = diagnostics
        update(&nextDiagnostics)
        diagnostics = nextDiagnostics
    }

    private func updateHostSummaries() {
        hosts = candidates.map { candidate in
            RemoteHostSummary(
                id: candidate.id,
                name: candidate.name,
                detail: candidate.endpointDescription,
                symbolName: candidate.symbolName,
                isSaved: candidate.isSaved,
                isManual: candidate.isManual,
                isActive: candidate.id == activeCandidateID
            )
        }
    }

    private func applyHostInfo(_ message: RemoteHostInfoMessage) {
        guard let activeCandidateID,
              let index = candidates.firstIndex(where: { $0.id == activeCandidateID }) else {
            return
        }

        candidates[index].name = message.displayName
        candidates[index].detail = candidates[index].endpointDescription
        candidates[index].symbolNameOverride = message.symbolName
        updateHostSummaries()
    }

    private func recordDiagnosticEvent(_ message: String) {
        updateDiagnostics { diagnostics in
            diagnostics.recentEvents.append("\(Date().formatted(date: .omitted, time: .standard)): \(message)")
            if diagnostics.recentEvents.count > 12 {
                diagnostics.recentEvents.removeFirst(diagnostics.recentEvents.count - 12)
            }
        }
    }

    private static func discoveryParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func isTransientDiscoveryResolutionFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("NoSuchRecord") ||
            message.contains("-65554")
    }

    private static let manualEndpointDefaultsKey = "RemoteFrameStreamClient.manualEndpoint"
    private static let savedManualEndpointsDefaultsKey = "RemoteFrameStreamClient.savedManualEndpoints"
    private static let appIconCacheDefaultsKey = "RemoteFrameStreamClient.appIconCache"
}

private extension RemoteFrameStreamConfiguration.PacketType {
    var allowsDuringStreamSelectionResetWait: Bool {
        switch self {
        case .wallpaper, .windowList, .appIcon, .streamDiagnostics, .developerActivity, .streamReset, .hostInfo:
            return true
        case .frame, .videoFormat, .videoFrame, .videoMask:
            return false
        }
    }
}

enum RemoteFrameStreamState: Equatable {
    case idle
    case searching
    case connecting(String)
    case connected(String)
    case live(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .searching:
            return "Searching"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .live:
            return "Live"
        case .failed:
            return "Offline"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Remote viewer idle."
        case .searching:
            return "Looking for Apperture. Use Connect to Mac for Tailscale."
        case .connecting(let host):
            return "Connecting to \(host)."
        case .connected(let host):
            return "Connected to \(host)."
        case .live(let host):
            return "Streaming from \(host)."
        case .failed(let message):
            return message
        }
    }

    var indicatorColor: UIColor {
        switch self {
        case .idle, .searching, .connecting:
            return .systemOrange
        case .connected, .live:
            return .systemGreen
        case .failed:
            return .systemRed
        }
    }

    var canDisconnect: Bool {
        switch self {
        case .searching, .connecting, .connected, .live:
            return true
        case .idle, .failed:
            return false
        }
    }
}

struct RemoteHostSummary: Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var symbolName: String
    var isSaved: Bool
    var isManual: Bool
    var isActive: Bool
}

struct RemoteConnectionDiagnostics: Equatable {
    var browserState = "Not started"
    var discoveredServices: [String] = []
    var candidates: [String] = []
    var activeCandidate: String?
    var manualEndpoint: String?
    var lastError: String?
    var recentEvents: [String] = []

    func report(state: RemoteFrameStreamState) -> String {
        var lines: [String] = [
            "State: \(state.title)",
            state.detail,
            "",
            "Manual endpoint: \(manualEndpoint ?? "None")",
            "Bonjour: \(browserState)",
            "Discovered services: \(discoveredServices.count)",
            "Candidates: \(candidates.count)"
        ]

        if let activeCandidate {
            lines.append("Active candidate: \(activeCandidate)")
        }

        if let lastError {
            lines.append("Last error: \(lastError)")
        }

        if !candidates.isEmpty {
            lines.append("")
            lines.append("Candidate list:")
            lines.append(contentsOf: candidates.map { "• \($0)" })
        }

        if !recentEvents.isEmpty {
            lines.append("")
            lines.append("Recent events:")
            lines.append(contentsOf: recentEvents.map { "• \($0)" })
        }

        return lines.joined(separator: "\n")
    }
}

private extension NWEndpoint {
    var serviceName: String? {
        guard case let .service(name, _, _, _) = self else { return nil }
        return name
    }

    var displayAddress: String {
        switch self {
        case .service(let name, let type, let domain, _):
            let normalizedDomain = domain.isEmpty ? "local." : domain
            return "\(name).\(type)\(normalizedDomain)"
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return String(describing: self)
        @unknown default:
            return String(describing: self)
        }
    }
}

private struct StreamEndpointCandidate: Equatable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
    var detail: String?
    var isSaved: Bool
    var symbolNameOverride: String?

    init(id: String, name: String, endpoint: NWEndpoint, detail: String? = nil, isSaved: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.detail = detail
        self.isSaved = isSaved
        self.symbolNameOverride = nil
    }

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        self.id = String(describing: endpoint)
        self.name = endpoint.serviceName?.replacingOccurrences(of: "Apperture ", with: "") ?? "Mac"
        self.detail = endpoint.displayAddress
        self.isSaved = false
        self.symbolNameOverride = nil
    }

    var diagnosticDescription: String {
        "\(name) — \(String(describing: endpoint))"
    }

    var endpointDescription: String {
        detail ?? endpoint.displayAddress
    }

    var isManual: Bool {
        id.hasPrefix("manual-")
    }

    var symbolName: String {
        if let symbolNameOverride {
            return symbolNameOverride
        }

        #if targetEnvironment(simulator)
        if id == "simulator-loopback" {
            return "macwindow"
        }
        #endif

        return isManual ? "macstudio" : "desktopcomputer"
    }

    static func == (lhs: StreamEndpointCandidate, rhs: StreamEndpointCandidate) -> Bool {
        lhs.id == rhs.id
    }
}

private struct ManualStreamEndpoint: Codable, Equatable {
    var host: String
    var port: UInt16

    init?(input: String) {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        let parsed: (host: String, port: UInt16)?
        if let components = URLComponents(string: trimmedInput),
           components.scheme != nil,
           let host = components.host {
            parsed = (host, UInt16(components.port ?? Int(RemoteFrameStreamConfiguration.tcpPort)))
        } else {
            parsed = Self.parseHostPort(trimmedInput)
        }

        guard let parsed else { return nil }
        let host = parsed.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, parsed.port > 0 else { return nil }

        self.host = host
        self.port = parsed.port
    }

    var id: String {
        "manual-\(storageValue)"
    }

    var displayName: String {
        host
    }

    var addressDescription: String {
        storageValue
    }

    var storageValue: String {
        "\(host):\(port)"
    }

    var endpoint: NWEndpoint {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            return .hostPort(host: .name(host, nil), port: .any)
        }

        return .hostPort(host: .name(host, nil), port: port)
    }

    private static func parseHostPort(_ input: String) -> (host: String, port: UInt16)? {
        if input.hasPrefix("["),
           let closingBracket = input.firstIndex(of: "]") {
            let host = String(input[input.index(after: input.startIndex)..<closingBracket])
            let remainder = input[input.index(after: closingBracket)...]
            let port = parsePortSuffix(String(remainder)) ?? RemoteFrameStreamConfiguration.tcpPort
            return (host, port)
        }

        let colonCount = input.reduce(0) { partial, character in
            partial + (character == ":" ? 1 : 0)
        }

        if colonCount == 1,
           let separator = input.lastIndex(of: ":") {
            let host = String(input[..<separator])
            let portText = String(input[input.index(after: separator)...])
            guard let port = UInt16(portText) else { return nil }
            return (host, port)
        }

        return (input, RemoteFrameStreamConfiguration.tcpPort)
    }

    private static func parsePortSuffix(_ suffix: String) -> UInt16? {
        guard suffix.hasPrefix(":") else { return nil }
        return UInt16(suffix.dropFirst())
    }
}
