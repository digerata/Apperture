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
    @Published private(set) var pairingManager = IOSPairingManager()
    @Published private(set) var pairingStatusMessage: String?
    let videoSampleBuffers = PassthroughSubject<CMSampleBuffer, Never>()
    var currentHostID: String? { activeCandidateID }

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
    private var manuallySelectedHostID: String?
    private var allowsAutomaticConnection = false
    private var savedManualEndpoints: [ManualStreamEndpoint] = []
    private var appIconCache: [String: Data] = [:]
    private var hostReachability: [String: HostReachabilityStatus] = [:]
    private var reachableEndpointOptions: [String: CandidateEndpointOption] = [:]
    private var reachabilityProbes: [String: ReachabilityProbe] = [:]
    private var consecutiveConnectionFailures = 0
    private let videoDecoder = RemoteVideoDecoder()
    private var nextSequenceNumber: UInt64 = 0
    private var lastKeyFrameRequestTime: CFAbsoluteTime = 0
    private var requiresVideoKeyFrame = false
    private var isAwaitingStreamResetAfterSelection = false
    private var streamDecodeGeneration: UInt64 = 0

    private var activeCandidate: StreamEndpointCandidate? {
        guard let activeCandidateID else { return nil }
        return candidates.first { $0.id == activeCandidateID }
    }

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

    func start(automaticallyConnect: Bool = false) {
        guard browser == nil else { return }
        allowsAutomaticConnection = automaticallyConnect
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
        if allowsAutomaticConnection {
            connectToNextCandidate()
        }
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        reachabilityProbes.values.forEach { probe in
            probe.timeout.cancel()
            probe.connection.cancel()
        }
        reachabilityProbes = [:]
        browser?.cancel()
        browser = nil
        browseResults = []
        connection?.cancel()
        connection = nil
        candidates = []
        hostReachability = [:]
        reachableEndpointOptions = [:]
        nextCandidateIndex = 0
        consecutiveConnectionFailures = 0
        connectedHostName = nil
        activeCandidateID = nil
        manuallySelectedHostID = nil
        allowsAutomaticConnection = false
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        streamDiagnostics = nil
        developerActivity = DeveloperActivityState(eventDirectoryPath: "")
        pairingStatusMessage = nil
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

    func restart(automaticallyConnect: Bool = false) {
        stop()
        start(automaticallyConnect: automaticallyConnect)
    }

    func send(_ message: RemoteControlMessage) {
        guard let connection else { return }
        guard let payload = try? JSONEncoder.apperture.encode(RemoteClientEnvelope.control(message)) else { return }
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

    private func sendEnvelope(_ envelope: RemoteClientEnvelope) {
        guard let connection else { return }
        guard let payload = try? JSONEncoder.apperture.encode(envelope) else { return }
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

    @discardableResult
    func connectForPairing(request: PairingRequest, offer: PairingOffer) -> String? {
        guard let endpointText = offer.endpointHints.first,
              let endpoint = ManualStreamEndpoint(input: endpointText) else {
            return "The QR code did not include a reachable Mac address."
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        pairingStatusMessage = nil
        connection?.cancel()
        connection = nil
        connectedHostName = offer.macDisplayName
        activeCandidateID = "pairing-\(offer.id)"
        consecutiveConnectionFailures = 0
        latestFrame = nil
        videoFrameSize = nil
        latestFrameMask = nil
        wallpaper = nil
        windows = []
        state = .connecting(offer.macDisplayName)
        pairingStatusMessage = "Sending pairing request to \(offer.macDisplayName)..."
        recordDiagnosticEvent("Starting pairing connection to \(offer.macDisplayName) at \(endpoint.displayName).")

        let connection = NWConnection(to: endpoint.endpoint, using: Self.connectionParameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            self?.handlePairingConnectionState(state, for: connection, request: request)
        }
        connection.start(queue: queue)
        return nil
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
        manuallySelectedHostID = nil
        consecutiveConnectionFailures = 0
        streamDecodeGeneration += 1
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
        if let index = candidates.firstIndex(where: { $0.id == endpoint.id }) {
            nextCandidateIndex = index
        }

        if browser == nil {
            start()
        } else if allowsAutomaticConnection {
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
        manuallySelectedHostID = nil
        consecutiveConnectionFailures = 0
        streamDecodeGeneration += 1
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
        if allowsAutomaticConnection {
            connectToNextCandidate()
        }
    }

    func forgetHost(withID hostID: RemoteHostSummary.ID) {
        guard let candidate = candidates.first(where: { $0.id == hostID }) else {
            recordDiagnosticEvent("Forget host ignored; candidate is unavailable.")
            return
        }

        if let pairedDevice = candidate.pairedDevice {
            pairingManager.forget(pairedDevice)
            recordDiagnosticEvent("Forgot paired host \(candidate.name).")
        } else if let endpoint = savedManualEndpoints.first(where: { $0.id == candidate.id }) {
            savedManualEndpoints.removeAll { $0.id == endpoint.id }
            Self.storeSavedManualEndpoints(savedManualEndpoints)
            manualEndpointDescription = savedManualEndpoints.first?.displayName
            updateDiagnostics { diagnostics in
                diagnostics.manualEndpoint = manualEndpointDescription
            }
            recordDiagnosticEvent("Forgot saved host \(endpoint.displayName).")
        } else {
            recordDiagnosticEvent("Forget host ignored; \(candidate.name) is not saved.")
            return
        }

        if activeCandidateID == candidate.id {
            connection?.cancel()
            connection = nil
            connectedHostName = nil
            activeCandidateID = nil
            state = .idle
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        hostReachability.removeValue(forKey: candidate.id)
        reachableEndpointOptions.removeValue(forKey: candidate.id)
        cancelReachabilityProbes(for: candidate.id)
        manuallySelectedHostID = nil
        nextCandidateIndex = 0
        rebuildCandidates(from: browseResults)
    }

    func connect(toHostID hostID: RemoteHostSummary.ID) {
        guard let candidate = candidates.first(where: { $0.id == hostID }) else {
            recordDiagnosticEvent("Host selection ignored; candidate is unavailable.")
            return
        }

        guard candidate.pairedDevice != nil else {
            pairingStatusMessage = "Pair this Mac before connecting. Scan the QR code shown on the Mac."
            state = .failed("Pair this Mac before connecting. Scan the QR code shown on the Mac.")
            recordDiagnosticEvent("Host selection ignored; \(candidate.name) is not paired.")
            return
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        pairingStatusMessage = nil
        connection?.cancel()
        connection = nil
        connectedHostName = nil
        activeCandidateID = nil
        manuallySelectedHostID = candidate.id
        connect(to: candidate)
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
            if self.allowsAutomaticConnection, self.retryWorkItem == nil {
                self.connectToNextCandidate()
            }
        }
    }

    private func rebuildCandidates(from results: Set<NWBrowser.Result>) {
        var updatedCandidates: [StreamEndpointCandidate] = []
        let discoveredCandidates = results.map { StreamEndpointCandidate(endpoint: $0.endpoint) }

        #if targetEnvironment(simulator)
        if let port = NWEndpoint.Port(rawValue: RemoteFrameStreamConfiguration.tcpPort) {
            updatedCandidates.append(
                StreamEndpointCandidate(
                    id: "simulator-loopback",
                    name: "Mac localhost",
                    endpoint: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: port),
                    detail: "Debug simulator pairing",
                    pairedDevice: DevelopmentPairing.simulatorDevice(peerDeviceID: pairingManager.localIdentity.id)
                )
            )
        }
        #endif

        pairingManager.loadPairings()
        let activePairedDevices = pairingManager.pairedMacs.filter { !$0.isRevoked }
        var discoveredCandidateIDsUsedForPairings = Set<String>()

        updatedCandidates.append(
            contentsOf: activePairedDevices
                .compactMap { device in
                    let matchingDiscoveredCandidates = discoveredCandidates.filter { candidate in
                        Self.hostNamesMatch(candidate.name, device.displayName)
                    }
                    matchingDiscoveredCandidates.forEach { discoveredCandidate in
                        discoveredCandidateIDsUsedForPairings.insert(discoveredCandidate.id)
                    }

                    let endpointOptions = Self.endpointOptions(
                        for: device,
                        discoveredCandidates: matchingDiscoveredCandidates
                    )
                    guard let firstEndpointOption = endpointOptions.first else {
                        return nil
                    }

                    return StreamEndpointCandidate(
                        id: "paired-\(device.id)",
                        name: device.displayName,
                        endpoint: firstEndpointOption.endpoint,
                        detail: firstEndpointOption.detail,
                        isSaved: true,
                        pairedDevice: device,
                        endpointOptions: endpointOptions
                    )
                }
        )

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
            contentsOf: discoveredCandidates.filter { candidate in
                !discoveredCandidateIDsUsedForPairings.contains(candidate.id) &&
                    !activePairedDevices.contains(where: { device in
                        Self.hostNamesMatch(candidate.name, device.displayName)
                    })
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
        pruneReachabilityState()
        updateHostSummaries()
        refreshHostReachability()
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

    private static func hostNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedHostName(lhs) == normalizedHostName(rhs)
    }

    private static func normalizedHostName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\\032", with: " ")
            .replacingOccurrences(of: "Apperture ", with: "")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func endpointOptions(
        for device: PairedDevice,
        discoveredCandidates: [StreamEndpointCandidate]
    ) -> [CandidateEndpointOption] {
        var options: [CandidateEndpointOption] = []

        options.append(contentsOf: discoveredCandidates.map { candidate in
            CandidateEndpointOption(
                endpoint: candidate.endpoint,
                detail: candidate.endpointDescription,
                priority: 0
            )
        })

        var endpointTexts = device.endpointHints
        if let lastEndpoint = device.lastEndpoint, !endpointTexts.contains(lastEndpoint) {
            endpointTexts.append(lastEndpoint)
        }

        options.append(
            contentsOf: endpointTexts.compactMap { endpointText in
                guard let endpoint = ManualStreamEndpoint(input: endpointText) else { return nil }
                return CandidateEndpointOption(
                    endpoint: endpoint.endpoint,
                    detail: endpoint.addressDescription,
                    priority: endpointPriority(forHost: endpoint.host)
                )
            }
        )

        var seenIDs = Set<String>()
        return options
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                return lhs.detail.localizedCaseInsensitiveCompare(rhs.detail) == .orderedAscending
            }
            .filter { option in
                guard !seenIDs.contains(option.id) else { return false }
                seenIDs.insert(option.id)
                return true
            }
    }

    private static func endpointPriority(forHost host: String) -> Int {
        if isTailscaleIPv4Address(host) {
            return 1
        }
        if isPrivateIPv4Address(host) {
            return 3
        }
        return 2
    }

    private static func isTailscaleIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isPrivateIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private func connectToNextCandidate() {
        guard connection == nil else { return }

        retryWorkItem?.cancel()
        retryWorkItem = nil

        let autoConnectCandidates = candidates.filter { candidate in
            candidate.pairedDevice != nil && hostReachability[candidate.id] == .reachable
        }

        guard !autoConnectCandidates.isEmpty else {
            state = candidates.isEmpty ? .searching : .idle
            return
        }

        let candidate = autoConnectCandidates[nextCandidateIndex % autoConnectCandidates.count]
        nextCandidateIndex = (nextCandidateIndex + 1) % autoConnectCandidates.count
        connect(to: candidate)
    }

    private func connect(to candidate: StreamEndpointCandidate) {
        let endpointOption = selectedEndpointOption(for: candidate)
        connectedHostName = candidate.name
        activeCandidateID = candidate.id
        clearRemoteContentForNewConnection()
        updateHostSummaries()
        state = .connecting(candidate.name)
        updateDiagnostics { diagnostics in
            diagnostics.activeCandidate = "\(candidate.name) — \(endpointOption.detail)"
            diagnostics.lastError = nil
        }
        recordDiagnosticEvent("Connecting to \(candidate.name) — \(endpointOption.detail).")

        let connection = NWConnection(to: endpointOption.endpoint, using: Self.connectionParameters())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            self?.handleConnectionState(state, for: connection)
        }

        connection.start(queue: queue)
        scheduleTimeout(for: connection, candidate: candidate)
    }

    private func clearRemoteContentForNewConnection() {
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
    }

    private nonisolated func handleConnectionState(_ connectionState: NWConnection.State, for connection: NWConnection?) {
        switch connectionState {
        case .ready:
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                let hostName = self.connectedHostName ?? "Mac"
                self.consecutiveConnectionFailures = 0
                self.state = .connecting(hostName)
                self.recordDiagnosticEvent("Connection ready, authenticating: \(hostName).")
                if let candidate = self.activeCandidate,
                   let pairedDevice = candidate.pairedDevice {
                    self.sendEnvelope(.authRequest(self.pairingManager.authRequest(for: pairedDevice)))
                } else {
                    self.handleConnectionFailure("Pair this Mac before connecting.")
                    return
                }
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

    private nonisolated func handlePairingConnectionState(
        _ connectionState: NWConnection.State,
        for connection: NWConnection?,
        request: PairingRequest
    ) {
        switch connectionState {
        case .ready:
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.recordDiagnosticEvent("Pairing connection ready.")
                self.sendEnvelope(.pairingRequest(request))
                self.pairingStatusMessage = "Pairing request sent. Approve it on your Mac."
                self.receiveLength()
            }
        case .waiting(let error), .failed(let error):
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.handleConnectionFailure(error.localizedDescription)
            }
        case .cancelled:
            Task { @MainActor in
                guard self.connection === connection else { return }
                self.handleConnectionFailure("Pairing connection cancelled.")
            }
        default:
            break
        }
    }

    private func receiveLength() {
        let activeConnection = connection
        activeConnection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak activeConnection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === activeConnection else { return }

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
        let activeConnection = connection
        activeConnection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak activeConnection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === activeConnection else { return }

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
                guard self.connection === activeConnection else { return }
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
            recordDiagnosticEvent("Received app list with \(message.windows.count) window(s).")
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
        case .pairingResponse:
            guard let response = try? JSONDecoder.apperture.decode(PairingResponse.self, from: Data(imageData)) else {
                return
            }
            switch response.status {
            case .accepted:
                if let pairedDevice = response.pairedDevice {
                    let hostName = response.hostProfile?.macDisplayName ?? pairingManager.pendingOffer?.macDisplayName ?? pairedDevice.displayName
                    pairingManager.accept(pairedDevice, hostProfile: response.hostProfile)
                    pairingStatusMessage = "Pairing approved. Connecting to \(hostName)..."
                    state = .connected(hostName)
                    recordDiagnosticEvent("Pairing accepted.")
                    restart(automaticallyConnect: true)
                }
            case .rejected, .expired:
                pairingManager.reject(response.message)
                pairingStatusMessage = "Pairing failed: \(response.message ?? "Pairing was not accepted.")"
                handleConnectionFailure(response.message ?? "Pairing was not accepted.")
            }
        case .authStatus:
            guard let response = try? JSONDecoder.apperture.decode(PairingAuthStatus.self, from: Data(imageData)) else {
                return
            }
            switch response.status {
            case .accepted:
                let hostName = connectedHostName ?? "Mac"
                pairingStatusMessage = nil
                state = .connected(hostName)
                recordDiagnosticEvent("Authenticated with \(hostName).")
            case .rejected:
                handleConnectionFailure(response.message ?? "Authentication failed.")
            }
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
        let wasPairingConnection = activeCandidateID?.hasPrefix("pairing-") == true
        let failedCandidateID = activeCandidateID
        let wasManualSelection = failedCandidateID == manuallySelectedHostID
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
        if let failedCandidateID, !wasPairingConnection {
            hostReachability[failedCandidateID] = .unreachable
            reachableEndpointOptions.removeValue(forKey: failedCandidateID)
        }
        updateHostSummaries()
        updateDiagnostics { diagnostics in
            diagnostics.lastError = message
            diagnostics.activeCandidate = nil
        }
        consecutiveConnectionFailures += 1
        recordDiagnosticEvent("Connection failed: \(message)")

        guard browser != nil else {
            state = .failed(message)
            return
        }

        if wasPairingConnection {
            pairingStatusMessage = "Pairing failed: \(message)"
            state = .failed(message)
            return
        }

        pairingStatusMessage = nil

        if wasManualSelection {
            state = .failed(message)
            return
        }

        let hasReachablePairedCandidate = candidates.contains { candidate in
            candidate.pairedDevice != nil && hostReachability[candidate.id] == .reachable
        }
        guard hasReachablePairedCandidate else {
            state = candidates.isEmpty || Self.isTransientDiscoveryResolutionFailure(message)
                ? .searching
                : .failed(message)
            return
        }

        state = candidates.isEmpty || Self.isTransientDiscoveryResolutionFailure(message)
            ? .searching
            : .failed(message)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let delay = retryDelay(forFailureCount: consecutiveConnectionFailures)

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.retryWorkItem = nil
                self?.connectToNextCandidate()
            }
        }

        retryWorkItem = workItem
        recordDiagnosticEvent("Retrying connection in \(String(format: "%.1f", delay))s.")
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func retryDelay(forFailureCount failureCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [1.0, 2.0, 4.0, 8.0, 15.0, 30.0]
        return delays[min(max(failureCount - 1, 0), delays.count - 1)]
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

    private func refreshHostReachability() {
        for candidate in candidates {
            startReachabilityProbe(for: candidate)
        }
    }

    private func startReachabilityProbe(for candidate: StreamEndpointCandidate) {
        guard hostReachability[candidate.id] != .reachable else { return }
        guard !reachabilityProbes.values.contains(where: { $0.candidateID == candidate.id }) else { return }
        if candidate.id == activeCandidateID {
            switch state {
            case .connected, .live:
                hostReachability[candidate.id] = .reachable
                reachableEndpointOptions[candidate.id] = selectedEndpointOption(for: candidate)
                updateHostSummaries()
                return
            case .idle, .searching, .connecting, .failed:
                break
            }
        }

        hostReachability[candidate.id] = .checking
        updateHostSummaries()

        for endpointOption in candidate.endpointOptions {
            let probeID = "\(candidate.id)|\(endpointOption.id)"
            let connection = NWConnection(to: endpointOption.endpoint, using: Self.connectionParameters())
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.finishReachabilityProbe(
                        probeID: probeID,
                        candidateID: candidate.id,
                        endpointOption: endpointOption,
                        status: .unreachable
                    )
                }
            }

            reachabilityProbes[probeID] = ReachabilityProbe(candidateID: candidate.id, connection: connection, timeout: timeout)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                Task { @MainActor in
                    guard let self,
                          let connection,
                          self.reachabilityProbes[probeID]?.connection === connection else {
                        return
                    }

                    switch state {
                    case .ready:
                        self.finishReachabilityProbe(
                            probeID: probeID,
                            candidateID: candidate.id,
                            endpointOption: endpointOption,
                            status: .reachable
                        )
                    case .failed:
                        self.finishReachabilityProbe(
                            probeID: probeID,
                            candidateID: candidate.id,
                            endpointOption: endpointOption,
                            status: .unreachable
                        )
                    case .waiting, .cancelled:
                        break
                    default:
                        break
                    }
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5, execute: timeout)
        }
    }

    private func finishReachabilityProbe(
        probeID: String,
        candidateID: String,
        endpointOption: CandidateEndpointOption,
        status: HostReachabilityStatus
    ) {
        guard let probe = reachabilityProbes.removeValue(forKey: probeID) else { return }
        probe.timeout.cancel()
        probe.connection.cancel()

        if status == .reachable {
            cancelReachabilityProbes(for: candidateID)
            reachableEndpointOptions[candidateID] = endpointOption
            hostReachability[candidateID] = .reachable
            updateHostSummaries()
            if allowsAutomaticConnection, connection == nil, retryWorkItem == nil {
                connectToNextCandidate()
            }
            return
        }

        if !reachabilityProbes.values.contains(where: { $0.candidateID == candidateID }),
           reachableEndpointOptions[candidateID] == nil {
            hostReachability[candidateID] = .unreachable
        }
        updateHostSummaries()
    }

    private func cancelReachabilityProbes(for candidateID: String) {
        let probeIDs = reachabilityProbes
            .filter { $0.value.candidateID == candidateID }
            .map(\.key)
        for probeID in probeIDs {
            guard let probe = reachabilityProbes.removeValue(forKey: probeID) else { continue }
            probe.timeout.cancel()
            probe.connection.cancel()
        }
    }

    private func pruneReachabilityState() {
        let candidateIDs = Set(candidates.map(\.id))
        hostReachability = hostReachability.filter { candidateIDs.contains($0.key) }
        reachableEndpointOptions = reachableEndpointOptions.filter { candidateIDs.contains($0.key) }

        let staleProbeIDs = reachabilityProbes
            .filter { !candidateIDs.contains($0.value.candidateID) }
            .map(\.key)
        for probeID in staleProbeIDs {
            guard let probe = reachabilityProbes.removeValue(forKey: probeID) else { continue }
            probe.timeout.cancel()
            probe.connection.cancel()
        }
    }

    private func updateDiagnostics(_ update: (inout RemoteConnectionDiagnostics) -> Void) {
        var nextDiagnostics = diagnostics
        update(&nextDiagnostics)
        diagnostics = nextDiagnostics
    }

    private func updateHostSummaries() {
        hosts = candidates.map { candidate in
            let endpointOption = selectedEndpointOption(for: candidate)
            return RemoteHostSummary(
                id: candidate.id,
                name: candidate.name,
                detail: candidate.pairedDevice == nil ? "Pair before connecting" : endpointOption.detail,
                symbolName: candidate.symbolName,
                isSaved: candidate.isSaved,
                isManual: candidate.isManual,
                isActive: candidate.id == activeCandidateID,
                canForget: candidate.pairedDevice != nil || candidate.isManual,
                reachabilityStatus: hostReachability[candidate.id] ?? .unknown
            )
        }
    }

    private func selectedEndpointOption(for candidate: StreamEndpointCandidate) -> CandidateEndpointOption {
        reachableEndpointOptions[candidate.id] ?? candidate.endpointOptions.first ?? CandidateEndpointOption(
            endpoint: candidate.endpoint,
            detail: candidate.endpointDescription,
            priority: 0
        )
    }

    private func selectedEndpoint(for candidate: StreamEndpointCandidate) -> NWEndpoint {
        selectedEndpointOption(for: candidate).endpoint
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

    private static func connectionParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
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
        case .wallpaper, .windowList, .appIcon, .streamDiagnostics, .developerActivity, .streamReset, .hostInfo, .pairingResponse, .authStatus:
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
            return "Looking for Apperture. Add a host for Tailscale or direct connections."
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

    var hasVisibleApp: Bool {
        if case .live = self {
            return true
        }
        return false
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
    var canForget: Bool
    var reachabilityStatus: HostReachabilityStatus
}

enum HostReachabilityStatus: Equatable {
    case unknown
    case checking
    case reachable
    case unreachable

    var displayText: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking"
        case .reachable:
            return "Reachable"
        case .unreachable:
            return "Unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            return "circle"
        case .checking:
            return "circle.dotted"
        case .reachable:
            return "circle.fill"
        case .unreachable:
            return "circle"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .unknown:
            return UIColor.white.withAlphaComponent(0.34)
        case .checking:
            return .systemYellow
        case .reachable:
            return .systemGreen
        case .unreachable:
            return UIColor.white.withAlphaComponent(0.34)
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
    var pairedDevice: PairedDevice?
    var endpointOptions: [CandidateEndpointOption]
    var symbolNameOverride: String?

    init(
        id: String,
        name: String,
        endpoint: NWEndpoint,
        detail: String? = nil,
        isSaved: Bool = false,
        pairedDevice: PairedDevice? = nil,
        endpointOptions: [CandidateEndpointOption]? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.detail = detail
        self.isSaved = isSaved
        self.pairedDevice = pairedDevice
        self.endpointOptions = endpointOptions ?? [
            CandidateEndpointOption(endpoint: endpoint, detail: detail ?? endpoint.displayAddress, priority: 0)
        ]
        self.symbolNameOverride = nil
    }

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        self.id = String(describing: endpoint)
        self.name = endpoint.serviceName?.replacingOccurrences(of: "Apperture ", with: "") ?? "Mac"
        self.detail = endpoint.displayAddress
        self.isSaved = false
        self.pairedDevice = nil
        self.endpointOptions = [
            CandidateEndpointOption(endpoint: endpoint, detail: endpoint.displayAddress, priority: 0)
        ]
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
        if let pairedDevice {
            return pairedDevice.symbolName
        }

        #if targetEnvironment(simulator)
        if id == "simulator-loopback" {
            return "macwindow"
        }
        #endif

        return isManual ? "macstudio" : "desktopcomputer"
    }

    static func == (lhs: StreamEndpointCandidate, rhs: StreamEndpointCandidate) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.endpointOptions == rhs.endpointOptions &&
            lhs.pairedDevice == rhs.pairedDevice
    }
}

private struct CandidateEndpointOption: Equatable {
    var id: String
    var endpoint: NWEndpoint
    var detail: String
    var priority: Int

    init(endpoint: NWEndpoint, detail: String, priority: Int) {
        self.id = String(describing: endpoint)
        self.endpoint = endpoint
        self.detail = detail
        self.priority = priority
    }
}

private struct ReachabilityProbe {
    var candidateID: String
    var connection: NWConnection
    var timeout: DispatchWorkItem
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
