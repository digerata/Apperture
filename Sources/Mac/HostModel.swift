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
    @Published private(set) var lastRefreshDate: Date?

    private let discoveryService = WindowDiscoveryService()
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
    }

    deinit {
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

    func startLiveView() {
        guard let window = selectedWindow else {
            streamStatus = .failed("Select a window first.")
            return
        }

        streamStatus = .starting(window.displayTitle)
        if let wallpaper = wallpaperService.wallpaperImage(for: window) {
            frameServer.publishWallpaper(wallpaper)
        }

        Task {
            do {
                try await liveCaptureService.start(
                    windowID: window.id,
                    mode: window.isLikelySimulator ? .simulator : .window,
                    onFrame: { [weak self] frame in
                        Task { @MainActor in
                            self?.liveFrame = frame.image
                            self?.latestCaptureScreenFrame = frame.screenFrame
                            self?.frameServer.publish(frame.image)
                            self?.streamStatus = .live(window.displayTitle)
                        }
                    },
                    onStop: { [weak self] error in
                        Task { @MainActor in
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
        default:
            guard let window = selectedWindow else { return }
            inputInjectionService.perform(message, in: window, targetFrame: latestCaptureScreenFrame)
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

        if streamStatus.isRunning {
            startLiveView()
        }
    }

    private func publishWindowList() {
        frameServer.publishWindowList(
            windows.filter { window in
                window.ownerName != "Apperture"
            }
            .map { window in
                RemoteWindowSummary(
                    id: window.id,
                    title: window.displayTitle,
                    subtitle: window.subtitle,
                    isSelected: window.id == selectedWindowID,
                    isSimulator: window.isLikelySimulator
                )
            }
        )
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
