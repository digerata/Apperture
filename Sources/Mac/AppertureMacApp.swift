import SwiftUI
import AppKit
import Sparkle

@main
struct AppertureMacApp: App {
    @NSApplicationDelegateAdaptor(AppertureAppDelegate.self) private var appDelegate
    @StateObject private var hostModel: HostModel

    init() {
        if let existingApp = Self.existingRunningInstance {
            DistributedNotificationCenter.default().postNotificationName(
                AppertureAppDelegate.focusNotificationName,
                object: nil,
                deliverImmediately: true
            )
            existingApp.activate(options: [.activateAllWindows])
            _hostModel = StateObject(wrappedValue: HostModel(startsServices: false))
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } else {
            _hostModel = StateObject(wrappedValue: HostModel())
        }
    }

    var body: some Scene {
        WindowGroup("Apperture Host", id: "host") {
            MacHostView()
                .environmentObject(hostModel)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    (NSApp.delegate as? AppertureAppDelegate)?.checkForUpdates(nil)
                }
                .disabled(!AppertureAppDelegate.sparkleIsConfigured)
            }
        }

        Window("Pair iPhone", id: "pairing") {
            PairingFlowView()
                .environmentObject(hostModel)
                .frame(width: 520)
                .frame(minHeight: 560)
        }

        Window("Device Sessions", id: "sessions") {
            DeviceSessionsView()
                .environmentObject(hostModel)
                .frame(minWidth: 760, minHeight: 520)
        }

        MenuBarExtra {
            HostMenuBarView()
                .environmentObject(hostModel)
        } label: {
            HostMenuBarLabel()
                .environmentObject(hostModel)
        }

        Settings {
            HostSettingsView()
                .environmentObject(hostModel)
        }
    }

    private static var existingRunningInstance: NSRunningApplication? {
        let currentProcessID = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != currentProcessID && !$0.isTerminated }
    }
}

private struct HostMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        Button("Open Host") {
            openWindow(id: "host")
        }

        Button("Pair iPhone") {
            openWindow(id: "pairing")
        }

        Button("Device Sessions") {
            openWindow(id: "sessions")
        }

        Button("Check for Updates...") {
            (NSApp.delegate as? AppertureAppDelegate)?.checkForUpdates(nil)
        }
        .disabled(!AppertureAppDelegate.sparkleIsConfigured)

        Divider()

        HostMenuStatusView()
            .environmentObject(hostModel)

        Divider()

        Button("Quit Apperture") {
            NSApp.terminate(nil)
        }
    }
}

private struct HostMenuBarLabel: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone.radiowaves.left.and.right")

            if hostModel.streamStatus.isRunning {
                Circle()
                    .fill(.blue)
                    .frame(width: 5, height: 5)
            }

            if !hostModel.connectedClients.isEmpty {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
            }
        }
        .background(MenuBarAnchorReader())
    }
}

private struct HostMenuStatusView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine(
                title: hostModel.streamStatus.isRunning ? "Mirroring" : "Not Mirroring",
                detail: streamingDetail,
                systemImage: hostModel.streamStatus.isRunning ? "rectangle.on.rectangle" : "rectangle.dashed"
            )

            statusLine(
                title: hostModel.connectedClients.isEmpty ? "No Client Connected" : clientSummary,
                detail: hostModel.frameServerStatus.detail,
                systemImage: hostModel.connectedClients.isEmpty ? "iphone.slash" : "iphone.radiowaves.left.and.right"
            )

            if !hostModel.connectedClients.isEmpty {
                Divider()
                ForEach(hostModel.connectedClients) { client in
                    Label(client.displayName, systemImage: client.symbolName)
                }
            }

            if hostModel.streamStatus.isRunning, let selectedWindow = hostModel.selectedWindow {
                Divider()
                HStack(spacing: 8) {
                    if let icon = hostModel.selectedWindowApplicationIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: selectedWindow.targetKind.symbolName)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedWindow.applicationName)
                        Text(selectedWindow.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var clientSummary: String {
        let count = hostModel.connectedClients.count
        return "\(count) Client\(count == 1 ? "" : "s") Connected"
    }

    private var streamingDetail: String {
        guard hostModel.streamStatus.isRunning,
              let selectedWindow = hostModel.selectedWindow else {
            return "No app is currently streaming."
        }

        return "\(selectedWindow.applicationName) - \(selectedWindow.displayTitle)"
    }

    private func statusLine(title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

final class AppertureAppDelegate: NSObject, NSApplicationDelegate {
    static let focusNotificationName = Notification.Name("com.landmk1.apperture.focusHost")
    static var sparkleIsConfigured: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feedURL) != nil,
              !feedURL.contains("example.com"),
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty,
              !publicKey.hasPrefix("$(") else {
            return false
        }

        return true
    }

    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(focusHostWindow),
            name: Self.focusNotificationName,
            object: nil
        )
        configureSoftwareUpdates()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        focusHostWindow()
        return true
    }

    @objc private func focusHostWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let hostWindow = NSApp.windows.first(where: { $0.title == "Apperture Host" }) {
            hostWindow.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    private func configureSoftwareUpdates() {
        guard Self.sparkleIsConfigured else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

struct HostSecurityAlert {
    var title: String
    var systemImage: String
    var tint: NSColor
}

@MainActor
final class HostSecurityAlertPresenter {
    static let shared = HostSecurityAlertPresenter()

    private let panelSize = CGSize(width: 340, height: 72)
    private var panel: NSPanel?
    private var pendingAlerts: [HostSecurityAlert] = []
    private var dismissWorkItem: DispatchWorkItem?
    private var isShowingAlert = false
    private var menuBarAnchorRect: CGRect?

    private init() {}

    func show(_ alert: HostSecurityAlert) {
        pendingAlerts.append(alert)
        showNextAlertIfNeeded()
    }

    func updateMenuBarAnchor(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        menuBarAnchorRect = rect
    }

    private func showNextAlertIfNeeded() {
        guard !isShowingAlert, !pendingAlerts.isEmpty else { return }
        isShowingAlert = true

        let alert = pendingAlerts.removeFirst()
        let panel = makePanelIfNeeded()
        panel.contentView = NSHostingView(rootView: HostSecurityAlertView(alert: alert))
        panel.setFrame(positionedFrame(for: panel), display: true)
        panel.orderFrontRegardless()

        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideCurrentAlert()
            }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func hideCurrentAlert() {
        panel?.orderOut(nil)
        isShowingAlert = false
        showNextAlertIfNeeded()
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func positionedFrame(for panel: NSPanel) -> CGRect {
        if let menuBarAnchorRect {
            let screen = NSScreen.screens.first { screen in
                screen.frame.intersects(menuBarAnchorRect)
            } ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? .zero
            let x = min(
                max(menuBarAnchorRect.midX - panelSize.width / 2, visibleFrame.minX + 8),
                visibleFrame.maxX - panelSize.width - 8
            )

            return CGRect(
                x: x,
                y: max(visibleFrame.minY + 8, menuBarAnchorRect.minY - panelSize.height - 8),
                width: panelSize.width,
                height: panelSize.height
            )
        }

        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main

        let visibleFrame = screen?.visibleFrame ?? .zero
        return CGRect(
            x: visibleFrame.maxX - panelSize.width - 12,
            y: visibleFrame.maxY - panelSize.height - 8,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

private struct MenuBarAnchorReader: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuBarAnchorView {
        MenuBarAnchorView()
    }

    func updateNSView(_ nsView: MenuBarAnchorView, context: Context) {
        nsView.publishAnchorRect()
    }
}

private final class MenuBarAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishAnchorRect()
    }

    override func layout() {
        super.layout()
        publishAnchorRect()
    }

    func publishAnchorRect() {
        guard let window else { return }
        let rectInWindow = convert(bounds, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        Task { @MainActor in
            HostSecurityAlertPresenter.shared.updateMenuBarAnchor(rectInScreen)
        }
    }
}

private struct HostSecurityAlertView: View {
    var alert: HostSecurityAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(nsColor: alert.tint))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("Apperture is active")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340, height: 72)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
