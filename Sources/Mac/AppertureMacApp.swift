import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(focusHostWindow),
            name: Self.focusNotificationName,
            object: nil
        )
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
}
