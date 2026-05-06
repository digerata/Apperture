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
    @Published private(set) var manualEndpointDescription: String?
    @Published private(set) var diagnostics = RemoteConnectionDiagnostics()
    @Published private(set) var streamDiagnostics: RemoteStreamDiagnosticsMessage?
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
    private var manualEndpoint: ManualStreamEndpoint?
    private let videoDecoder = RemoteVideoDecoder()

    init() {
        if let savedEndpoint = UserDefaults.standard.string(forKey: Self.manualEndpointDefaultsKey),
           let endpoint = ManualStreamEndpoint(input: savedEndpoint) {
            manualEndpoint = endpoint
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
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        streamDiagnostics = nil
        videoDecoder.reset()
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

    func clearCurrentFrame() {
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        streamDiagnostics = nil
        videoDecoder.reset()
    }

    @discardableResult
    func connectManually(to input: String) -> String? {
        guard let endpoint = ManualStreamEndpoint(input: input) else {
            return "Enter a Mac hostname, MagicDNS name, or Tailscale IP."
        }

        manualEndpoint = endpoint
        manualEndpointDescription = endpoint.displayName
        UserDefaults.standard.set(endpoint.storageValue, forKey: Self.manualEndpointDefaultsKey)
        updateDiagnostics { diagnostics in
            diagnostics.manualEndpoint = endpoint.displayName
        }
        recordDiagnosticEvent("Manual endpoint set to \(endpoint.displayName).")

        connection?.cancel()
        connection = nil
        connectedHostName = nil
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)

        if browser == nil {
            start()
        } else {
            connectToNextCandidate()
        }

        return nil
    }

    func forgetManualEndpoint() {
        guard manualEndpoint != nil else { return }

        manualEndpoint = nil
        manualEndpointDescription = nil
        UserDefaults.standard.removeObject(forKey: Self.manualEndpointDefaultsKey)
        updateDiagnostics { diagnostics in
            diagnostics.manualEndpoint = nil
        }
        recordDiagnosticEvent("Manual endpoint removed.")

        connection?.cancel()
        connection = nil
        connectedHostName = nil
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
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

        if let manualEndpoint {
            updatedCandidates.append(
                StreamEndpointCandidate(
                    id: manualEndpoint.id,
                    name: manualEndpoint.displayName,
                    endpoint: manualEndpoint.endpoint
                )
            )
        }

        updatedCandidates.append(
            contentsOf: results.map { result in
                StreamEndpointCandidate(endpoint: result.endpoint)
            }
            .sorted { $0.id < $1.id }
        )

        guard updatedCandidates != candidates else { return }
        candidates = updatedCandidates
        updateDiagnostics { diagnostics in
            diagnostics.candidates = updatedCandidates.map(\.diagnosticDescription)
        }
        if nextCandidateIndex >= candidates.count {
            nextCandidateIndex = 0
        }
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
            handleLegacyFrame(data)
            return
        }

        let imageData = data.dropFirst()

        switch type {
        case .frame:
            guard let image = UIImage(data: Data(imageData)) else { return }
            let hostName = connectedHostName ?? "Mac"
            videoFrameSize = nil
            latestFrame = image
            state = .live(hostName)
        case .wallpaper:
            guard let image = UIImage(data: Data(imageData)) else { return }
            wallpaper = image
        case .windowList:
            guard let message = try? JSONDecoder().decode(RemoteWindowListMessage.self, from: Data(imageData)) else {
                return
            }
            windows = message.windows
        case .videoFormat:
            guard let message = try? JSONDecoder().decode(RemoteVideoFormatMessage.self, from: Data(imageData)) else {
                return
            }
            videoFrameSize = CGSize(width: CGFloat(message.width), height: CGFloat(message.height))
            videoDecoder.configure(message)
        case .videoFrame:
            guard let message = RemoteVideoFrameMessage.decodePayload(Data(imageData)) else {
                return
            }
            videoDecoder.decode(message) { [weak self] sampleBuffer, size in
                Task { @MainActor in
                    guard let self else { return }
                    let hostName = self.connectedHostName ?? "Mac"
                    if size.width > 0, size.height > 0 {
                        self.videoFrameSize = size
                    }
                    self.videoSampleBuffers.send(sampleBuffer)
                    self.state = .live(hostName)
                }
            }
        case .videoMask:
            latestFrameMask = imageData.isEmpty ? nil : UIImage(data: Data(imageData))
        case .streamDiagnostics:
            guard let message = try? JSONDecoder().decode(RemoteStreamDiagnosticsMessage.self, from: Data(imageData)) else {
                return
            }
            streamDiagnostics = message
        }
    }

    private func handleLegacyFrame(_ data: Data) {
        guard let image = UIImage(data: data) else { return }

        let hostName = connectedHostName ?? "Mac"
        videoFrameSize = nil
        latestFrame = image
        state = .live(hostName)
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
        videoDecoder.reset()
        connection?.cancel()
        connection = nil
        connectedHostName = nil
        updateDiagnostics { diagnostics in
            diagnostics.lastError = message
            diagnostics.activeCandidate = nil
        }
        recordDiagnosticEvent("Connection failed: \(message)")

        guard browser != nil else {
            state = .failed(message)
            return
        }

        state = candidates.isEmpty ? .searching : .failed(message)
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

    private static let manualEndpointDefaultsKey = "RemoteFrameStreamClient.manualEndpoint"
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
}

private struct StreamEndpointCandidate: Equatable {
    var id: String
    var name: String
    var endpoint: NWEndpoint

    init(id: String, name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        self.id = String(describing: endpoint)
        self.name = endpoint.serviceName ?? "Mac"
    }

    var diagnosticDescription: String {
        "\(name) — \(String(describing: endpoint))"
    }

    static func == (lhs: StreamEndpointCandidate, rhs: StreamEndpointCandidate) -> Bool {
        lhs.id == rhs.id
    }
}

private struct ManualStreamEndpoint: Equatable {
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
