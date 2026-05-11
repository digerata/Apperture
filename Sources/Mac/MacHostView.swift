import AppKit
import SwiftUI

struct MacHostView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            previewPane
        }
        .task {
            hostModel.refreshAll()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apperture")
                            .font(.title2.weight(.semibold))
                        Text("Mac Host")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        hostModel.refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }

                PermissionSummaryView()
                FrameServerSummaryView()
                PairingSummaryView(pairingManager: hostModel.pairingManager)
                DeveloperActivitySummaryView()
                if hostModel.windowShapeProbeState.isVisible {
                    WindowShapeProbeSummaryView()
                }
            }
            .padding(20)

            Divider()

            List(selection: $hostModel.selectedWindowID) {
                ForEach(ApplicationWindowGroup.make(from: hostModel.windows)) { group in
                    Section {
                        ForEach(group.windows) { window in
                            WindowRow(window: window)
                                .tag(window.id)
                        }
                    } header: {
                        ApplicationGroupHeader(group: group)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HostToolbarView()

            Divider()

            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)

                    VStack(spacing: 20) {
                        CapturePreviewView(
                            image: hostModel.liveFrame,
                            selectedWindow: hostModel.selectedWindow,
                            availableSize: proxy.size
                        )

                        StatusStripView(status: hostModel.streamStatus)
                    }
                    .padding(24)
                }
            }
        }
    }
}

private struct WindowShapeProbeSummaryView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hostModel.windowShapeProbeState.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(hostModel.windowShapeProbeState.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if let outputDirectoryURL = hostModel.windowShapeProbeState.outputDirectoryURL {
                Divider()

                HStack(spacing: 8) {
                    Text(outputDirectoryURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        hostModel.revealWindowShapeProbeOutput()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal probe output")
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var symbolName: String {
        switch hostModel.windowShapeProbeState {
        case .idle:
            return "camera.metering.matrix"
        case .running:
            return "camera.metering.center.weighted"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch hostModel.windowShapeProbeState {
        case .idle:
            return .secondary
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct DeveloperActivitySummaryView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hostModel.developerActivity.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(hostModel.developerActivity.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if let issueSummary = hostModel.developerActivity.issueSummary {
                Text(issueSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hostModel.developerActivity.latestEvent?.isFailure == true ? .red : .orange)
            }

            Divider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Events")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(hostModel.developerActivity.eventDirectoryPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    hostModel.copyDeveloperActivityDirectory()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy agent events folder")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var symbolName: String {
        guard let event = hostModel.developerActivity.latestEvent else {
            return "terminal"
        }

        if event.isFailure {
            return "xmark.circle.fill"
        }

        switch event.kind {
        case "buildStarted":
            return "hammer.fill"
        case "testStarted":
            return "checkmark.seal"
        case "appLaunched":
            return "play.circle.fill"
        case "simulatorBooted":
            return "iphone.gen3"
        default:
            return "terminal.fill"
        }
    }

    private var symbolColor: Color {
        guard let event = hostModel.developerActivity.latestEvent else {
            return .secondary
        }

        if event.isFailure {
            return .red
        }

        return event.isActive ? .blue : .green
    }
}

private struct PermissionSummaryView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(spacing: 8) {
            PermissionRow(
                title: "Screen Recording",
                isGranted: hostModel.permissions.screenCaptureGranted,
                actionTitle: hostModel.permissions.screenCaptureGranted ? "Open" : "Allow",
                action: {
                    if hostModel.permissions.screenCaptureGranted {
                        hostModel.openScreenRecordingSettings()
                    } else {
                        hostModel.requestScreenCaptureAccess()
                    }
                }
            )

            PermissionRow(
                title: "Accessibility",
                isGranted: hostModel.permissions.accessibilityGranted,
                actionTitle: "Open",
                action: hostModel.openAccessibilitySettings
            )
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct FrameServerSummaryView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(symbolColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hostModel.frameServerStatus.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(hostModel.frameServerStatus.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if shouldShowConnectionHints {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect from iPhone")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    if hostModel.connectionHints.isEmpty {
                        Text("No network address detected.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(hostModel.connectionHints) { hint in
                            ConnectionHintRow(hint: hint)
                        }
                    }
                }
            }

            Divider()

            Button {
                hostModel.beginPhonePairing()
            } label: {
                Label("Pair Phone", systemImage: "qrcode")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var symbolName: String {
        switch hostModel.frameServerStatus {
        case .offline:
            return "antenna.radiowaves.left.and.right.slash"
        case .online:
            return "antenna.radiowaves.left.and.right"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch hostModel.frameServerStatus {
        case .offline:
            return .secondary
        case .online:
            return .green
        case .failed:
            return .orange
        }
    }

    private var shouldShowConnectionHints: Bool {
        switch hostModel.frameServerStatus {
        case .online:
            return true
        case .offline, .failed:
            return false
        }
    }
}

private struct PairingSummaryView: View {
    @EnvironmentObject private var hostModel: HostModel
    @ObservedObject var pairingManager: MacPairingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundColor(pairingManager.pairedDevices.isEmpty ? .secondary : .green)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Paired Devices")
                        .font(.system(size: 13, weight: .medium))
                    Text(summaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if let pairingStatusMessage = pairingManager.pairingStatusMessage {
                Label(pairingStatusMessage, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let image = pairingManager.qrImage(), let offer = pairingManager.activeOffer {
                Divider()

                VStack(spacing: 12) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(.rect(cornerRadius: 8))

                    Text("Scan from iPhone. Expires \(offer.expiresAt, style: .timer).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let pendingRequest = pairingManager.pendingRequest {
                        VStack(spacing: 8) {
                            Label(
                                "\(pendingRequest.request.phoneIdentity.displayName) wants to pair.",
                                systemImage: pendingRequest.request.phoneIdentity.symbolName
                            )
                            .font(.system(size: 12, weight: .medium))

                            HStack(spacing: 8) {
                                Button("Reject") {
                                    hostModel.rejectPendingPairing()
                                }
                                Button("Allow") {
                                    hostModel.approvePendingPairing()
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                    }

                    Button("Cancel Pairing") {
                        hostModel.cancelPhonePairing()
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
            }

            if !pairingManager.pairedDevices.isEmpty {
                Divider()

                ForEach(pairingManager.pairedDevices.filter { !$0.isRevoked }) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(device.lastSeenAt.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not connected yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            hostModel.revokePairing(device)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Revoke \(device.displayName)")
                    }
                }
            }

            if !pairingManager.auditRecords.isEmpty {
                Divider()
                Text("\(pairingManager.auditRecords.count) session\(pairingManager.auditRecords.count == 1 ? "" : "s") in the last 30 days.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var summaryText: String {
        let activeCount = pairingManager.pairedDevices.filter { !$0.isRevoked }.count
        if activeCount == 0 {
            return "No phones paired yet."
        }
        return "\(activeCount) trusted phone\(activeCount == 1 ? "" : "s")."
    }
}

private struct ConnectionHintRow: View {
    @EnvironmentObject private var hostModel: HostModel
    var hint: HostConnectionHint

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hint.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(hint.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(hint.endpointText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                hostModel.copyConnectionHint(hint)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(hint.endpointText)")
        }
    }
}

private struct PermissionRow: View {
    var title: String
    var isGranted: Bool
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Button(actionTitle, action: action)
                .buttonStyle(.link)
        }
    }
}

private struct ApplicationWindowGroup: Identifiable {
    var id: String
    var name: String
    var iconPNGData: Data?
    var windows: [MirrorWindow]

    var containsSimulator: Bool {
        windows.contains(where: \.isLikelySimulator)
    }

    static func make(from windows: [MirrorWindow]) -> [ApplicationWindowGroup] {
        Dictionary(grouping: windows) { $0.applicationGroupID }
            .values
            .map { windows in
                let sortedWindows = windows.sorted { lhs, rhs in
                    lhs.windowListTitle.localizedCaseInsensitiveCompare(rhs.windowListTitle) == .orderedAscending
                }
                let firstWindow = sortedWindows[0]
                return ApplicationWindowGroup(
                    id: firstWindow.applicationGroupID,
                    name: firstWindow.applicationName,
                    iconPNGData: sortedWindows.first(where: { $0.applicationIconPNGData != nil })?.applicationIconPNGData,
                    windows: sortedWindows
                )
            }
            .sorted { lhs, rhs in
                if lhs.containsSimulator != rhs.containsSimulator {
                    return lhs.containsSimulator
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

private struct ApplicationGroupHeader: View {
    var group: ApplicationWindowGroup

    var body: some View {
        HStack(spacing: 8) {
            ApplicationIconView(
                iconPNGData: group.iconPNGData,
                fallbackSystemName: group.containsSimulator ? "iphone.gen3" : "app.fill",
                size: 18
            )

            Text(group.name)
                .font(.system(size: 11, weight: .semibold))

            Spacer()

            if group.windows.count > 1 {
                Text("\(group.windows.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}

private struct ApplicationIconView: View {
    var iconPNGData: Data?
    var fallbackSystemName: String
    var size: CGFloat

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var nsImage: NSImage? {
        guard let iconPNGData else { return nil }
        return NSImage(data: iconPNGData)
    }
}

private struct WindowRow: View {
    var window: MirrorWindow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: window.targetKind.symbolName)
                .foregroundStyle(window.isLikelySimulator ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(window.windowListTitle)
                    .lineLimit(1)

                Text(window.windowListSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HostToolbarView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hostModel.selectedWindow?.displayTitle ?? "No Window Selected")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Text(hostModel.selectedWindow?.subtitle ?? "Waiting for target selection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                hostModel.runWindowShapeProbe()
            } label: {
                Label("Probe Shape", systemImage: "camera.metering.matrix")
            }
            .disabled(hostModel.selectedWindow == nil || hostModel.windowShapeProbeState.isRunning)
            .help("Capture window shape variants")

            Button {
                if hostModel.streamStatus.isRunning {
                    hostModel.stopLiveView()
                } else {
                    hostModel.startLiveView()
                }
            } label: {
                Label(
                    hostModel.streamStatus.isRunning ? "Stop Live View" : "Start Live View",
                    systemImage: hostModel.streamStatus.isRunning ? "stop.circle" : "play.circle"
                )
            }
            .disabled(hostModel.selectedWindow == nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct CapturePreviewView: View {
    var image: CGImage?
    var selectedWindow: MirrorWindow?
    var availableSize: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))

            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(16)
            } else {
                EmptyPreviewView(selectedWindow: selectedWindow)
                    .padding(24)
            }
        }
        .frame(maxWidth: availableSize.width, maxHeight: availableSize.height)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct EmptyPreviewView: View {
    var selectedWindow: MirrorWindow?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedWindow == nil ? "macwindow.badge.plus" : "camera.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(selectedWindow == nil ? "No Target Selected" : "Live View Idle")
                    .font(.title3.weight(.semibold))

                Text(selectedWindow == nil ? "Window preview unavailable." : "Live stream unavailable.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct StatusStripView: View {
    var status: LiveStreamStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var symbolName: String {
        switch status {
        case .idle:
            return "viewfinder"
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .live:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .idle:
            return .secondary
        case .starting:
            return .blue
        case .live:
            return .green
        case .failed:
            return .orange
        }
    }
}
