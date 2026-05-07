import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class HostModel: ObservableObject {
    @Published private(set) var windows: [MirrorWindow] = []
    @Published var selectedWindowID: MirrorWindow.ID?
    @Published private(set) var permissions = HostPermissionState.current
    @Published private(set) var liveFrame: CGImage?
    @Published private(set) var streamStatus: LiveStreamStatus = .idle
    @Published private(set) var frameServerStatus: FrameServerStatus = .offline
    @Published private(set) var connectionHints: [HostConnectionHint] = []
    @Published private(set) var developerActivity = DeveloperActivityState(
        eventDirectoryPath: AgentEventBridgeService.defaultEventDirectoryURL.path
    )
    @Published private(set) var lastRefreshDate: Date?

    private let discoveryService = WindowDiscoveryService()
    private let agentEventBridge = AgentEventBridgeService()
    private let liveCaptureService = LiveWindowCaptureService()
    private let frameServer = RemoteFrameStreamServer()
    private let inputInjectionService = RemoteInputInjectionService()
    private let wallpaperService = DesktopWallpaperService()
    private let networkAddressService = HostNetworkAddressService()
    private var latestCaptureScreenFrame: CGRect?

    init() {
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
        frameServer.resetVideoStream()
        if let wallpaper = wallpaperService.wallpaperImage(for: window) {
            frameServer.publishWallpaper(wallpaper)
        }

        Task {
            do {
                if let bootstrapFrame = await LiveWindowCaptureService.bootstrapFrame(for: window, mode: captureMode) {
                    liveFrame = bootstrapFrame.previewImage
                    latestCaptureScreenFrame = bootstrapFrame.screenFrame
                    frameServer.publish(bootstrapFrame, includeAlphaMask: window.isLikelySimulator)
                }

                try await liveCaptureService.start(
                    windowID: window.id,
                    mode: captureMode,
                    onFrame: { [weak self] frame in
                        Task { @MainActor in
                            if let image = frame.previewImage {
                                self?.liveFrame = image
                            }
                            self?.latestCaptureScreenFrame = frame.screenFrame
                            self?.frameServer.publish(frame, includeAlphaMask: window.isLikelySimulator)
                            self?.streamStatus = .live(window.displayTitle)
                        }
                    },
                    onStop: { [weak self] error in
                        Task { @MainActor in
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
            liveFrame = nil
            latestCaptureScreenFrame = nil
            frameServer.resetVideoStream()
            streamStatus = .idle
        }
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

    private func handleRemoteControl(_ message: RemoteControlMessage) {
        switch message.kind {
        case .requestWindowList:
            refreshWindows()
            publishWindowList()
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
        }
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

    private func publishWindowList() {
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
        publishApplicationIcons(for: streamableWindows)
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
