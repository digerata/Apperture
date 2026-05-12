import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var windows: [MirrorWindow] = []
    @Published var selectedWindowID: MirrorWindow.ID?
    @Published private(set) var permissions = HostPermissionState.current
    @Published private(set) var liveFrame: CGImage?
    @Published private(set) var streamStatus: LiveStreamStatus = .idle {
        didSet {
            handleStreamStatusChange(from: oldValue, to: streamStatus)
        }
    }
    @Published private(set) var frameServerStatus: FrameServerStatus = .offline {
        didSet {
            handleConnectedClientsChange(from: oldValue.connectedClients, to: frameServerStatus.connectedClients)
        }
    }
    @Published private(set) var connectionHints: [HostConnectionHint] = []
    @Published private(set) var developerActivity = DeveloperActivityState(
        eventDirectoryPath: AgentEventBridgeService.defaultEventDirectoryURL.path
    )
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var pairingManager = MacPairingManager()

    private let discoveryService = WindowDiscoveryService()
    private let agentEventBridge = AgentEventBridgeService()
    private let liveCaptureService = LiveWindowCaptureService()
    private let frameServer = RemoteFrameStreamServer()
    private let inputInjectionService = RemoteInputInjectionService()
    private let wallpaperService = DesktopWallpaperService()
    private let networkAddressService = HostNetworkAddressService()
    private let liveFramePreviewScheduler = LiveFramePreviewScheduler()
    private let remoteWindowListRefreshCoalescingInterval: TimeInterval = 1
    private var latestCaptureScreenFrame: CGRect?
    private var clipboardSequenceNumber: UInt64 = 0
    private var lastPublishedClipboardChangeCount = NSPasteboard.general.changeCount
    private var activeAuditSessionIDs: [UUID: String] = [:]
    private var pendingPairingConnectionID: UUID?
    private var activeStreamingApplicationName: String?

    init(startsServices: Bool = true) {
        guard startsServices else { return }

        frameServer.start(
            statusHandler: { [weak self] status in
                Task { @MainActor in
                    self?.frameServerStatus = status
                    self?.refreshConnectionHints()
                }
            },
            controlHandler: { [weak self] message in
                Task { @MainActor in
                    self?.handleRemoteControl(message)
                }
            },
            clipboardHandler: { [weak self] message in
                Task { @MainActor in
                    self?.handleRemoteClipboard(message)
                }
            },
            pairingRequestHandler: { [weak self] connectionID, request, endpoint in
                Task { @MainActor in
                    _ = self?.pairingManager.submit(request, remoteEndpoint: endpoint)
                    self?.pendingPairingConnectionID = connectionID
                }
            },
            authRequestHandler: { [weak self] request, endpoint in
                guard let self else { return nil }
                return DispatchQueue.main.sync {
                    self.pairingManager.authenticate(request, remoteEndpoint: endpoint)
                }
            },
            connectionAuthenticatedHandler: { [weak self] connectionID, device, endpoint in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshWindows()
                    let auditRecord = self.pairingManager.beginAuditSession(device: device, remoteEndpoint: endpoint)
                    self.activeAuditSessionIDs[connectionID] = auditRecord.id
                }
            },
            connectionClosedHandler: { [weak self] connectionID, _, reason in
                Task { @MainActor in
                    guard let self,
                          let sessionID = self.activeAuditSessionIDs.removeValue(forKey: connectionID) else { return }
                    self.pairingManager.endAuditSession(sessionID, reason: reason)
                }
            }
        )

        agentEventBridge.start { [weak self] event in
            Task { @MainActor in
                self?.handleDeveloperActivity(event)
            }
        }
    }

    deinit {
        agentEventBridge.stop()
        frameServer.stop()
    }

    var selectedWindow: MirrorWindow? {
        windows.first { $0.id == selectedWindowID }
    }

    var connectedClients: [ConnectedFrameClient] {
        frameServerStatus.connectedClients
    }

    var selectedWindowApplicationIcon: NSImage? {
        guard let selectedWindow else { return nil }
        return NSRunningApplication(processIdentifier: selectedWindow.processID)?.icon
    }

    func refreshAll() {
        refreshPermissions()
        refreshWindows()
        refreshConnectionHints()
    }

    func refreshPermissions() {
        let currentPermissions = HostPermissionState.current
        permissions = currentPermissions

        Task {
            let canAccessShareableContent = await LiveWindowCaptureService.canAccessShareableContent()
            permissions = HostPermissionState(
                screenCaptureGranted: canAccessShareableContent || CGPreflightScreenCaptureAccess(),
                accessibilityGranted: AXIsProcessTrusted()
            )
        }
    }

    func refreshWindows() {
        windows = discoveryService.discoverWindows()
        lastRefreshDate = Date()

        if selectedWindowID == nil || selectedWindow == nil {
            selectedWindowID = windows.first(where: \.isLikelySimulator)?.id ?? windows.first?.id
        }

        publishWindowList()
    }

    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func openScreenRecordingSettings() {
        openSystemSettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSystemSettings(anchor: "Privacy_Accessibility")
    }

    func copyConnectionHint(_ hint: HostConnectionHint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint.endpointText, forType: .string)
    }

    func copyDeveloperActivityDirectory() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(developerActivity.eventDirectoryPath, forType: .string)
    }

    func startLiveView() {
        guard let window = selectedWindow else {
            streamStatus = .failed("Select a window first.")
            return
        }

        streamStatus = .starting(window.displayTitle)
        let captureMode: LiveCaptureMode = window.isLikelySimulator ? .simulator : .window
        let frameServer = self.frameServer
        let liveFramePreviewScheduler = self.liveFramePreviewScheduler
        liveFramePreviewScheduler.reset()
        frameServer.resetVideoStream()
        if let wallpaper = wallpaperService.wallpaperImage(for: window) {
            frameServer.publishWallpaper(wallpaper)
        }

        Task {
            do {
                if let bootstrapFrame = await LiveWindowCaptureService.bootstrapFrame(for: window, mode: captureMode) {
                    liveFrame = bootstrapFrame.previewImage
                    latestCaptureScreenFrame = bootstrapFrame.screenFrame
                    frameServer.publish(bootstrapFrame, includeAlphaMask: true)
                }

                try await liveCaptureService.start(
                    windowID: window.id,
                    mode: captureMode,
                    shouldProcessFrame: { [frameServer] in
                        frameServer.reserveFrameSlot()
                    },
                    onFrame: { [weak self, frameServer, liveFramePreviewScheduler] frame in
                        frameServer.publish(frame, includeAlphaMask: true, frameSlotReserved: true)

                        guard liveFramePreviewScheduler.reserveSlot() else { return }
                        let previewImage = frame.previewImage
                        let screenFrame = frame.screenFrame

                        Task { @MainActor in
                            defer {
                                liveFramePreviewScheduler.completeSlot()
                            }

                            if let image = previewImage {
                                self?.liveFrame = image
                            }
                            self?.latestCaptureScreenFrame = screenFrame
                            self?.streamStatus = .live(window.displayTitle)
                        }
                    },
                    onStop: { [weak self] error in
                        Task { @MainActor in
                            self?.liveFramePreviewScheduler.reset()
                            self?.liveFrame = nil
                            self?.latestCaptureScreenFrame = nil
                            self?.frameServer.resetVideoStream()
                            self?.streamStatus = .failed(error.localizedDescription)
                        }
                    }
                )
                permissions = HostPermissionState(
                    screenCaptureGranted: true,
                    accessibilityGranted: AXIsProcessTrusted()
                )
                streamStatus = .live(window.displayTitle)
            } catch {
                liveFramePreviewScheduler.reset()
                liveFrame = nil
                latestCaptureScreenFrame = nil
                frameServer.resetVideoStream()
                refreshPermissions()
                streamStatus = .failed(error.localizedDescription)
            }
        }
    }

    func stopLiveView() {
        Task {
            await liveCaptureService.stop()
            liveFramePreviewScheduler.reset()
            liveFrame = nil
            latestCaptureScreenFrame = nil
            frameServer.resetVideoStream()
            streamStatus = .idle
        }
    }

    func beginPhonePairing() {
        let endpointHints = connectionHints
            .sorted { lhs, rhs in
                pairingHintPriority(lhs.kind) < pairingHintPriority(rhs.kind)
            }
            .map(\.endpointText)
        pairingManager.beginPairing(
            endpointHints: endpointHints,
            port: RemoteFrameStreamConfiguration.tcpPort
        )
    }

    func cancelPhonePairing() {
        pendingPairingConnectionID = nil
        pairingManager.cancelPairing()
    }

    func approvePendingPairing() {
        guard let response = pairingManager.approvePendingRequest(),
              let connectionID = pendingPairingConnectionID else { return }
        pendingPairingConnectionID = nil
        frameServer.completePairing(connectionID: connectionID, response: response)
    }

    func rejectPendingPairing() {
        guard let response = pairingManager.rejectPendingRequest(),
              let connectionID = pendingPairingConnectionID else { return }
        pendingPairingConnectionID = nil
        frameServer.completePairing(connectionID: connectionID, response: response)
    }

    func revokePairing(_ device: PairedDevice) {
        pairingManager.revoke(device)
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshConnectionHints() {
        switch frameServerStatus {
        case .online(let port, _):
            connectionHints = networkAddressService.connectionHints(port: port)
        case .offline, .failed:
            connectionHints = []
        }
    }

    private func pairingHintPriority(_ kind: HostConnectionHint.Kind) -> Int {
        switch kind {
        case .hostname:
            return 0
        case .tailscale:
            return 1
        case .localNetwork:
            return 2
        }
    }

    private func handleRemoteControl(_ message: RemoteControlMessage) {
        switch message.kind {
        case .requestWindowList:
            refreshWindowsForRemoteRequest()
        case .selectWindow:
            guard let windowID = message.windowID else { return }
            selectRemoteWindow(windowID)
        case .startStream:
            startLiveViewForRemoteRequest()
        case .requestKeyFrame:
            return
        default:
            guard let window = selectedWindow else { return }
            inputInjectionService.perform(message, in: window, targetFrame: latestCaptureScreenFrame)
            publishClipboardAfterCopyIfNeeded(for: message)
        }
    }

    private func handleRemoteClipboard(_ message: RemoteClipboardMessage) {
        guard message.kind == .plainText else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        lastPublishedClipboardChangeCount = pasteboard.changeCount
    }

    private func publishClipboardAfterCopyIfNeeded(for message: RemoteControlMessage) {
        guard isClipboardProducingCommand(message) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.publishCurrentClipboardIfChanged()
        }
    }

    private func publishCurrentClipboardIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPublishedClipboardChangeCount else { return }
        guard let text = pasteboard.string(forType: .string) else {
            lastPublishedClipboardChangeCount = pasteboard.changeCount
            return
        }

        lastPublishedClipboardChangeCount = pasteboard.changeCount
        clipboardSequenceNumber += 1
        frameServer.publishClipboard(RemoteClipboardMessage(text: text, sequenceNumber: clipboardSequenceNumber))
    }

    private func isClipboardProducingCommand(_ message: RemoteControlMessage) -> Bool {
        guard message.kind == .keyChord,
              let text = message.text?.lowercased(),
              text.count == 1,
              Set(message.modifiers ?? []) == Set([.command]) else {
            return false
        }

        return text == "c" || text == "x"
    }

    private func refreshWindowsForRemoteRequest() {
        if let lastRefreshDate,
           Date().timeIntervalSince(lastRefreshDate) < remoteWindowListRefreshCoalescingInterval {
            publishWindowList(includeApplicationIcons: false)
            return
        }

        refreshWindows()
    }

    private func handleDeveloperActivity(_ event: DeveloperActivityEvent) {
        developerActivity.apply(event)
        frameServer.publishDeveloperActivity(event)

        guard event.kind == "appLaunched" else { return }
        selectLaunchedTarget(from: event)
    }

    private func selectLaunchedTarget(from event: DeveloperActivityEvent) {
        refreshWindows()

        if let processID = event.pid,
           let launchedWindow = windows.first(where: { $0.processID == Int32(processID) }) {
            selectedWindowID = launchedWindow.id
            publishWindowList()
            restartLiveViewIfNeeded()
            return
        }

        if event.platform == "simulator",
           let simulatorWindow = windows.first(where: \.isLikelySimulator) {
            selectedWindowID = simulatorWindow.id
            publishWindowList()
            restartLiveViewIfNeeded()
        }
    }

    private func selectRemoteWindow(_ windowID: MirrorWindow.ID) {
        refreshWindows()
        guard windows.contains(where: { $0.id == windowID }) else {
            publishWindowList()
            return
        }

        selectedWindowID = windowID
        publishWindowList()
        if let sessionID = activeAuditSessionIDs.values.first,
           let window = selectedWindow {
            pairingManager.recordWindowSelection(
                SessionWindowSelection(
                    appName: window.applicationName,
                    windowTitle: window.displayTitle,
                    selectedAt: Date()
                ),
                in: sessionID
            )
        }

        startLiveView()
    }

    private func startLiveViewForRemoteRequest() {
        refreshWindows()
        publishWindowList()

        guard selectedWindow != nil else {
            streamStatus = .failed("No streamable windows are available.")
            return
        }

        guard !streamStatus.isRunning else { return }
        startLiveView()
    }

    private func restartLiveViewIfNeeded() {
        guard streamStatus.isRunning else { return }
        startLiveView()
    }

    private func handleStreamStatusChange(from oldStatus: LiveStreamStatus, to newStatus: LiveStreamStatus) {
        guard oldStatus.isRunning != newStatus.isRunning || newStatus.isRunning else { return }

        if newStatus.isRunning {
            let applicationName = selectedWindow?.applicationName ?? newStatus.targetName ?? "selected app"
            if applicationName != activeStreamingApplicationName {
                activeStreamingApplicationName = applicationName
                HostSecurityAlertPresenter.shared.show(
                    HostSecurityAlert(
                        title: "Started streaming \(applicationName)",
                        systemImage: "record.circle",
                        tint: .systemBlue
                    )
                )
            }
            return
        }

        let applicationName = activeStreamingApplicationName ?? selectedWindow?.applicationName ?? oldStatus.targetName ?? "selected app"
        activeStreamingApplicationName = nil
        HostSecurityAlertPresenter.shared.show(
            HostSecurityAlert(
                title: "Stopped streaming \(applicationName)",
                systemImage: "stop.circle",
                tint: .systemGray
            )
        )
    }

    private func handleConnectedClientsChange(from oldClients: [ConnectedFrameClient], to newClients: [ConnectedFrameClient]) {
        let oldIDs = Set(oldClients.map(\.id))
        let newIDs = Set(newClients.map(\.id))
        let connectedClients = newClients.filter { !oldIDs.contains($0.id) }
        let disconnectedClients = oldClients.filter { !newIDs.contains($0.id) }

        for client in connectedClients {
            HostSecurityAlertPresenter.shared.show(
                HostSecurityAlert(
                    title: "\(client.displayName) connected",
                    systemImage: client.symbolName,
                    tint: .systemGreen
                )
            )
        }

        for client in disconnectedClients {
            HostSecurityAlertPresenter.shared.show(
                HostSecurityAlert(
                    title: "\(client.displayName) disconnected",
                    systemImage: client.symbolName,
                    tint: .systemOrange
                )
            )
        }
    }

    private func publishWindowList(includeApplicationIcons: Bool = true) {
        let streamableWindows = windows.filter { window in
            window.ownerName != "Apperture"
        }
        let summaries = streamableWindows.map { window in
            RemoteWindowSummary(
                id: window.id,
                title: window.windowListTitle,
                subtitle: window.windowListSubtitle,
                isSelected: window.id == selectedWindowID,
                isSimulator: window.isLikelySimulator,
                appName: window.applicationName,
                appBundleIdentifier: window.applicationBundleIdentifier,
                appIconPNGData: nil
            )
        }

        frameServer.publishWindowList(summaries)
        if includeApplicationIcons {
            publishApplicationIcons(for: streamableWindows)
        }
    }

    private func publishApplicationIcons(for windows: [MirrorWindow]) {
        let uniqueWindows = Dictionary(grouping: windows, by: \.applicationGroupID)
            .compactMap { _, windows in windows.first }

        DispatchQueue.global(qos: .utility).async { [frameServer] in
            for window in uniqueWindows {
                guard let iconPNGData = WindowDiscoveryService.applicationIconPNGData(for: window.processID) else {
                    continue
                }

                frameServer.publishApplicationIcon(
                    RemoteAppIconMessage(
                        appGroupID: window.applicationGroupID,
                        pngData: iconPNGData
                    )
                )
            }
        }
    }
}

private final class LiveFramePreviewScheduler {
    private let lock = NSLock()
    private let minimumInterval: CFAbsoluteTime = 1.0 / 6.0
    private var nextPreviewTime: CFAbsoluteTime = 0
    private var updateInFlight = false

    func reserveSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        guard !updateInFlight, now >= nextPreviewTime else { return false }

        updateInFlight = true
        nextPreviewTime = now + minimumInterval
        return true
    }

    func completeSlot() {
        lock.lock()
        updateInFlight = false
        lock.unlock()
    }

    func reset() {
        lock.lock()
        nextPreviewTime = 0
        updateInFlight = false
        lock.unlock()
    }
}

enum LiveStreamStatus: Equatable {
    case idle
    case starting(String)
    case live(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Live View Idle"
        case .starting:
            return "Starting Live View"
        case .live:
            return "Live"
        case .failed:
            return "Live View Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "No selected-window stream is running."
        case .starting(let target):
            return "Starting \(target)."
        case .live(let target):
            return "Streaming \(target) with ScreenCaptureKit."
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .live:
            return true
        case .idle, .failed:
            return false
        }
    }

    var targetName: String? {
        switch self {
        case .starting(let target), .live(let target):
            return target
        case .idle, .failed:
            return nil
        }
    }
}

struct HostPermissionState: Equatable {
    var screenCaptureGranted: Bool
    var accessibilityGranted: Bool

    static var current: HostPermissionState {
        HostPermissionState(
            screenCaptureGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }
}
