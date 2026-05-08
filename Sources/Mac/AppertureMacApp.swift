import SwiftUI
import AppKit

@main
struct AppertureMacApp: App {
    @StateObject private var hostModel = HostModel()

    var body: some Scene {
        WindowGroup("Apperture Host", id: "host") {
            MacHostView()
                .environmentObject(hostModel)
                .frame(minWidth: 980, minHeight: 640)
        }

        MenuBarExtra("Apperture", systemImage: "iphone.radiowaves.left.and.right") {
            HostMenuBarView()
                .environmentObject(hostModel)
        }

        Settings {
            HostSettingsView()
                .environmentObject(hostModel)
        }
    }
}

private struct HostMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        Button("Open Host") {
            openWindow(id: "host")
        }

        Button("Refresh Windows") {
            hostModel.refreshWindows()
        }

        if let selectedWindow = hostModel.selectedWindow {
            Divider()
            Text(selectedWindow.ownerName)
            Text(selectedWindow.displayTitle)
            Button(hostModel.streamStatus.isRunning ? "Stop Live View" : "Start Live View") {
                if hostModel.streamStatus.isRunning {
                    hostModel.stopLiveView()
                } else {
                    hostModel.startLiveView()
                }
            }

            Button("Run Shape Probe") {
                hostModel.runWindowShapeProbe()
            }
            .disabled(hostModel.windowShapeProbeState.isRunning)
        }

        Divider()

        Button("Quit Apperture") {
            NSApp.terminate(nil)
        }
    }
}
