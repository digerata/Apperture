import AppKit
import SwiftUI

struct MacHostView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            dashboard
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            hostModel.refreshAll()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apperture Host")
                    .font(.title2.weight(.semibold))

                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openWindow(id: "pairing")
            } label: {
                Label("Pair iPhone", systemImage: "qrcode.viewfinder")
            }

            Button {
                openWindow(id: "sessions")
            } label: {
                Label("Sessions", systemImage: "clock.arrow.circlepath")
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                hostModel.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh host status")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusBadgeRow()
                    .environmentObject(hostModel)

                if hasPermissionIssue {
                    PermissionSummaryView()
                        .environmentObject(hostModel)
                }

                HStack(alignment: .top, spacing: 20) {
                    CurrentMirrorPanel()
                        .environmentObject(hostModel)

                    HostReadinessPanel()
                        .environmentObject(hostModel)
                        .frame(width: 280)
                }

                DisclosureGroup("Connection Details") {
                    ConnectionDetailsView()
                        .environmentObject(hostModel)
                        .padding(.top, 8)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(.rect(cornerRadius: 10))

                if shouldShowDeveloperActivity {
                    DeveloperActivitySummaryView()
                        .environmentObject(hostModel)
                }
            }
            .padding(24)
        }
    }

    private var hasPermissionIssue: Bool {
        !hostModel.permissions.screenCaptureGranted || !hostModel.permissions.accessibilityGranted
    }

    private var shouldShowDeveloperActivity: Bool {
        guard let latestEvent = hostModel.developerActivity.latestEvent else { return false }
        return latestEvent.isActive || latestEvent.isFailure
    }

    private var headerDetail: String {
        if hostModel.streamStatus.isRunning, let selectedWindow = hostModel.selectedWindow {
            return "Mirroring \(selectedWindow.applicationName) to \(clientText)."
        }

        return "Ready for iPhone-driven mirroring."
    }

    private var clientText: String {
        let count = hostModel.connectedClients.count
        guard count > 0 else { return "no clients" }
        if count == 1, let client = hostModel.connectedClients.first {
            return client.displayName
        }
        return "\(count) clients"
    }
}

private struct StatusBadgeRow: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(
                title: serverTitle,
                systemImage: "antenna.radiowaves.left.and.right",
                color: serverColor
            )

            StatusBadge(
                title: hostModel.streamStatus.isRunning ? "Mirroring" : "Idle",
                systemImage: hostModel.streamStatus.isRunning ? "rectangle.on.rectangle" : "pause.circle",
                color: hostModel.streamStatus.isRunning ? .blue : .secondary
            )

            StatusBadge(
                title: clientTitle,
                systemImage: hostModel.connectedClients.isEmpty ? "iphone.slash" : "iphone.radiowaves.left.and.right",
                color: hostModel.connectedClients.isEmpty ? .secondary : .green
            )

            StatusBadge(
                title: permissionsTitle,
                systemImage: permissionsOK ? "checkmark.shield" : "exclamationmark.shield",
                color: permissionsOK ? .green : .orange
            )
        }
    }

    private var permissionsOK: Bool {
        hostModel.permissions.screenCaptureGranted && hostModel.permissions.accessibilityGranted
    }

    private var permissionsTitle: String {
        permissionsOK ? "Permissions OK" : "Needs Permission"
    }

    private var clientTitle: String {
        let count = hostModel.connectedClients.count
        return count == 0 ? "No Client" : "\(count) Client\(count == 1 ? "" : "s")"
    }

    private var serverTitle: String {
        switch hostModel.frameServerStatus {
        case .offline:
            return "Offline"
        case .online:
            return "Ready"
        case .failed:
            return "Server Issue"
        }
    }

    private var serverColor: Color {
        switch hostModel.frameServerStatus {
        case .offline:
            return .secondary
        case .online:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct StatusBadge: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.capsule)
    }
}

private struct CurrentMirrorPanel: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = mirroredWindowIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: mirroredWindow?.targetKind.symbolName ?? "macwindow")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mirroredWindow?.displayTitle ?? "Waiting for iPhone Selection")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)

                    Text(mirroredWindow?.subtitle ?? "Choose an app from the iPhone to begin mirroring.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            GeometryReader { proxy in
                CapturePreviewView(
                    image: hostModel.liveFrame,
                    selectedWindow: mirroredWindow,
                    availableSize: proxy.size
                )
            }
            .frame(minHeight: 360)

            StatusStripView(status: hostModel.streamStatus)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var mirroredWindow: MirrorWindow? {
        hostModel.streamStatus.isRunning ? hostModel.selectedWindow : nil
    }

    private var mirroredWindowIcon: NSImage? {
        mirroredWindow == nil ? nil : hostModel.selectedWindowApplicationIcon
    }
}

private struct HostReadinessPanel: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Host Readiness")
                .font(.system(size: 13, weight: .semibold))

            ReadinessRow(
                title: hostModel.frameServerStatus.title,
                detail: hostModel.frameServerStatus.detail,
                systemImage: serverSymbolName,
                color: serverColor
            )

            ReadinessRow(
                title: clientTitle,
                detail: clientDetail,
                systemImage: hostModel.connectedClients.isEmpty ? "iphone.slash" : "iphone.radiowaves.left.and.right",
                color: hostModel.connectedClients.isEmpty ? .secondary : .green
            )

            ReadinessRow(
                title: permissionsOK ? "Permissions OK" : "Permissions Needed",
                detail: permissionsDetail,
                systemImage: permissionsOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: permissionsOK ? .green : .orange
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var permissionsOK: Bool {
        hostModel.permissions.screenCaptureGranted && hostModel.permissions.accessibilityGranted
    }

    private var permissionsDetail: String {
        if permissionsOK {
            return "Screen recording and input control are available."
        }

        if !hostModel.permissions.screenCaptureGranted && !hostModel.permissions.accessibilityGranted {
            return "Screen Recording and Accessibility are needed."
        }

        return hostModel.permissions.screenCaptureGranted ? "Accessibility is needed for input." : "Screen Recording is needed for mirroring."
    }

    private var clientTitle: String {
        let count = hostModel.connectedClients.count
        return count == 0 ? "No Client Connected" : "\(count) Client\(count == 1 ? "" : "s") Connected"
    }

    private var clientDetail: String {
        if hostModel.connectedClients.isEmpty {
            return "Open Apperture on iPhone to connect."
        }

        return hostModel.connectedClients.map(\.displayName).joined(separator: ", ")
    }

    private var serverSymbolName: String {
        switch hostModel.frameServerStatus {
        case .offline:
            return "antenna.radiowaves.left.and.right.slash"
        case .online:
            return "antenna.radiowaves.left.and.right"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var serverColor: Color {
        switch hostModel.frameServerStatus {
        case .offline:
            return .secondary
        case .online:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct ReadinessRow: View {
    var title: String
    var detail: String
    var systemImage: String
    var color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct ConnectionDetailsView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadinessRow(
                title: hostModel.frameServerStatus.title,
                detail: hostModel.frameServerStatus.detail,
                systemImage: symbolName,
                color: symbolColor
            )

            if hostModel.connectionHints.isEmpty {
                Text("No network addresses are available right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Addresses")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(hostModel.connectionHints) { hint in
                        ConnectionHintRow(hint: hint)
                    }
                }
            }
        }
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
}

struct PairingFlowView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        PairingFlowContentView(pairingManager: hostModel.pairingManager)
            .environmentObject(hostModel)
    }
}

private struct PairingFlowContentView: View {
    @EnvironmentObject private var hostModel: HostModel
    @ObservedObject var pairingManager: MacPairingManager

    var body: some View {
        VStack(spacing: 0) {
            pairingHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pairingCard
                    trustedDevicesCard

                    if !pairingManager.auditRecords.isEmpty {
                        recentActivityCard
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            hostModel.refreshAll()
        }
    }

    private var pairingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pair iPhone")
                .font(.title2.weight(.semibold))

            Text("Create a one-time code, approve the phone, and keep trusted devices here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var pairingCard: some View {
        if let image = pairingManager.qrImage(), let offer = pairingManager.activeOffer {
            HStack(alignment: .top, spacing: 24) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 184, height: 184)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan This Code")
                            .font(.headline)

                        Text("Expires \(offer.expiresAt, style: .timer)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    if let statusMessage = pairingManager.pairingStatusMessage {
                        Label(statusMessage, systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    if let pendingRequest = pairingManager.pendingRequest {
                        PendingPairingRequestView(request: pendingRequest)
                            .environmentObject(hostModel)
                    }

                    Spacer(minLength: 0)

                    Button("Cancel Pairing") {
                        hostModel.cancelPhonePairing()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("Ready to Pair", systemImage: "qrcode.viewfinder")
                    .font(.headline)

                Text("Generate a fresh QR code and scan it from the iPhone app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let statusMessage = pairingManager.pairingStatusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button {
                    hostModel.beginPhonePairing()
                } label: {
                    Label("Create Pairing Code", systemImage: "qrcode")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var trustedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trusted Devices")
                    .font(.headline)

                Spacer()

                Text("\(activeDevices.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if activeDevices.isEmpty {
                EmptyStateRow(
                    systemImage: "iphone.slash",
                    title: "No phones paired",
                    detail: "Paired iPhones will appear here."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(activeDevices) { device in
                        PairedDeviceRow(device: device)
                            .environmentObject(hostModel)

                        if device.id != activeDevices.last?.id {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var recentActivityCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Sessions")
                    .font(.system(size: 13, weight: .medium))
                Text("\(pairingManager.auditRecords.count) session\(pairingManager.auditRecords.count == 1 ? "" : "s") in the last \(PairingConstants.auditRetentionDays) days.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var activeDevices: [PairedDevice] {
        pairingManager.pairedDevices.filter { !$0.isRevoked }
    }
}

private struct PendingPairingRequestView: View {
    @EnvironmentObject private var hostModel: HostModel
    var request: PendingPairingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.request.phoneIdentity.displayName) wants to pair.")
                        .font(.system(size: 13, weight: .medium))
                    Text(request.remoteEndpoint ?? "Endpoint unavailable")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: request.request.phoneIdentity.symbolName)
            }

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
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct PairedDeviceRow: View {
    @EnvironmentObject private var hostModel: HostModel
    var device: PairedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(deviceDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .padding(.vertical, 10)
    }

    private var deviceDetail: String {
        if let lastSeenAt = device.lastSeenAt {
            return "Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))"
        }

        return "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct DeviceSessionsView: View {
    @EnvironmentObject private var hostModel: HostModel

    var body: some View {
        DeviceSessionsContentView(pairingManager: hostModel.pairingManager)
    }
}

private struct DeviceSessionsContentView: View {
    @ObservedObject var pairingManager: MacPairingManager

    var body: some View {
        VStack(spacing: 0) {
            sessionsHeader

            Divider()

            if pairingManager.auditRecords.isEmpty {
                EmptyStateRow(
                    systemImage: "clock.badge.questionmark",
                    title: "No sessions yet",
                    detail: "Connected iPhone sessions will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pairingManager.auditRecords) { record in
                    SessionRecordRow(record: record)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Device Sessions")
                    .font(.title2.weight(.semibold))

                Text("Recent iPhone connections, selected windows, and disconnect details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(pairingManager.auditRecords.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(.capsule)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct SessionRecordRow: View {
    var record: SessionAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.isActive ? "iphone.radiowaves.left.and.right" : record.networkKind.symbolName)
                    .foregroundStyle(record.isActive ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(record.pairedDeviceName)
                            .font(.system(size: 13, weight: .semibold))

                        Text(record.statusTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(record.isActive ? .green : .secondary)
                    }

                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(record.durationText)
                        .font(.system(size: 13, weight: .medium))
                    Text(record.networkKind.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if let latestSelection = record.latestWindowSelection {
                Label {
                    Text("\(latestSelection.appName) - \(latestSelection.windowTitle)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "macwindow")
                }
                .foregroundStyle(.secondary)
            }

            if !record.selectedWindows.isEmpty {
                DisclosureGroup("Selected Windows") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(record.selectedWindows, id: \.selectedAt) { selection in
                            HStack(spacing: 8) {
                                Text(selection.selectedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selection.appName)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(selection.windowTitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
            }

            if let remoteAddress = record.remoteAddress {
                SessionDetailLine(title: "Remote", value: remoteAddress)
            }

            if let disconnectReason = record.disconnectReason {
                SessionDetailLine(title: "Ended", value: disconnectReason)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct SessionDetailLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct EmptyStateRow: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
}

private extension SessionAuditRecord {
    var isActive: Bool {
        endedAt == nil
    }

    var statusTitle: String {
        isActive ? "Active" : "Ended"
    }

    var latestWindowSelection: SessionWindowSelection? {
        selectedWindows.max { lhs, rhs in
            lhs.selectedAt < rhs.selectedAt
        }
    }

    var durationText: String {
        let endDate = endedAt ?? Date()
        let interval = max(0, endDate.timeIntervalSince(startedAt))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "0s"
    }
}

private extension SessionAuditRecord.NetworkKind {
    var title: String {
        switch self {
        case .localNetwork:
            return "Local Network"
        case .tailnet:
            return "Tailnet"
        case .privateNetwork:
            return "Private Network"
        case .loopback:
            return "Loopback"
        case .unknown:
            return "Unknown Network"
        }
    }

    var symbolName: String {
        switch self {
        case .localNetwork:
            return "wifi"
        case .tailnet:
            return "point.3.connected.trianglepath.dotted"
        case .privateNetwork:
            return "network"
        case .loopback:
            return "desktopcomputer"
        case .unknown:
            return "questionmark.circle"
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
