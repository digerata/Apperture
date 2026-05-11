import AppKit
import CoreImage
import Foundation

@MainActor
final class MacPairingManager: ObservableObject {
    @Published private(set) var localIdentity: LocalDeviceIdentity
    @Published private(set) var activeOffer: PairingOffer?
    @Published private(set) var activeOfferQRCodeImage: NSImage?
    @Published private(set) var pairingStatusMessage: String?
    @Published private(set) var pendingRequest: PendingPairingRequest?
    @Published private(set) var pairedDevices: [PairedDevice]
    @Published private(set) var auditRecords: [SessionAuditRecord]

    private let identityStore = DeviceIdentityStore()
    private let pairedDeviceStore = PairedDeviceStore()
    private let auditStore = SessionAuditStore()

    init() {
        let displayName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        localIdentity = identityStore.loadOrCreate(displayName: displayName, kind: .mac)
        pairedDevices = pairedDeviceStore.load()
        auditRecords = auditStore.loadPruningExpiredRecords()
    }

    func beginPairing(endpointHints: [String], port: UInt16) {
        let hostName = ProcessInfo.processInfo.hostName
        activeOffer = PairingOffer(
            macIdentity: localIdentity,
            hostName: hostName,
            endpointHints: endpointHints,
            port: port
        )
        activeOfferQRCodeImage = makeQRCodeImage(from: activeOffer?.qrPayload)
        pairingStatusMessage = "Waiting for iPhone to scan this code."
        pendingRequest = nil
    }

    func cancelPairing() {
        activeOffer = nil
        activeOfferQRCodeImage = nil
        pairingStatusMessage = nil
        pendingRequest = nil
    }

    func submit(_ request: PairingRequest, remoteEndpoint: String?) -> PairingResponse {
        guard let offer = activeOffer else {
            pairingStatusMessage = "Pairing request received, but there is no active code."
            return .rejected("No active pairing offer.")
        }

        guard !offer.isExpired() else {
            activeOffer = nil
            activeOfferQRCodeImage = nil
            pairingStatusMessage = "Pairing code expired. Create a new code."
            return PairingResponse(status: .expired, pairedDevice: nil, hostProfile: nil, message: "The pairing code expired.")
        }

        guard request.offerID == offer.id, request.hasValidProof(for: offer) else {
            pairingStatusMessage = "Rejected an invalid pairing request."
            return .rejected("The pairing proof did not match this Mac.")
        }

        pendingRequest = PendingPairingRequest(
            request: request,
            remoteEndpoint: remoteEndpoint,
            receivedAt: Date()
        )
        pairingStatusMessage = "Review the pairing request from \(request.phoneIdentity.displayName)."
        return .rejected("Waiting for approval on the Mac.")
    }

    func approvePendingRequest() -> PairingResponse? {
        guard let offer = activeOffer,
              let pendingRequest else {
            return nil
        }

        let phoneIdentity = pendingRequest.request.phoneIdentity
        let pairedDevice = PairedDevice(
            peerDeviceID: phoneIdentity.id,
            displayName: phoneIdentity.displayName,
            kind: phoneIdentity.kind,
            symbolName: phoneIdentity.symbolName,
            sharedSecret: offer.secret,
            pairedAt: Date(),
            lastEndpoint: pendingRequest.remoteEndpoint,
            endpointHints: pendingRequest.remoteEndpoint.map { [$0] } ?? []
        )

        pairedDeviceStore.upsert(pairedDevice)
        pairedDevices = pairedDeviceStore.load()
        self.activeOffer = nil
        self.activeOfferQRCodeImage = nil
        self.pairingStatusMessage = "Paired with \(phoneIdentity.displayName)."
        self.pendingRequest = nil
        return .accepted(pairedDevice, hostProfile: PairingHostProfile(offer: offer))
    }

    func rejectPendingRequest() -> PairingResponse? {
        guard let pendingRequest else { return nil }
        pairingStatusMessage = "Rejected \(pendingRequest.request.phoneIdentity.displayName)."
        self.pendingRequest = nil
        return .rejected("Pairing was rejected on the Mac.")
    }

    func authenticate(_ request: PairingAuthRequest, remoteEndpoint: String?) -> PairedDevice? {
        guard var device = pairedDevices.first(where: { device in
            !device.isRevoked &&
                device.id == request.pairID &&
                device.peerDeviceID == request.peerDeviceID &&
                request.hasValidProof(sharedSecret: device.sharedSecret)
        }) else {
            #if DEBUG
            if PrivateNetworkClassifier.isAllowedPrivateEndpoint(remoteEndpoint),
               DevelopmentPairing.isValidSimulatorAuthRequest(request) {
                return DevelopmentPairing.simulatorDevice(peerDeviceID: request.peerDeviceID)
            }
            #endif

            return nil
        }

        device.lastSeenAt = Date()
        device.lastEndpoint = remoteEndpoint
        if let remoteEndpoint, !device.endpointHints.contains(remoteEndpoint) {
            device.endpointHints.insert(remoteEndpoint, at: 0)
        }
        pairedDeviceStore.upsert(device)
        pairedDevices = pairedDeviceStore.load()
        return device
    }

    func revoke(_ device: PairedDevice) {
        pairedDeviceStore.revoke(device.id)
        pairedDevices = pairedDeviceStore.load()
    }

    func beginAuditSession(device: PairedDevice, remoteEndpoint: String?) -> SessionAuditRecord {
        let record = SessionAuditRecord(
            pairedDeviceID: device.id,
            pairedDeviceName: device.displayName,
            networkKind: PrivateNetworkClassifier.networkKind(for: remoteEndpoint),
            remoteAddress: remoteEndpoint
        )
        auditStore.upsert(record)
        auditRecords = auditStore.loadPruningExpiredRecords()
        return record
    }

    func recordWindowSelection(_ selection: SessionWindowSelection, in sessionID: String) {
        auditStore.append(selection, to: sessionID)
        auditRecords = auditStore.loadPruningExpiredRecords()
    }

    func endAuditSession(_ sessionID: String, reason: String?) {
        auditStore.endSession(sessionID, reason: reason)
        auditRecords = auditStore.loadPruningExpiredRecords()
    }

    func qrImage() -> NSImage? {
        activeOfferQRCodeImage
    }

    private func makeQRCodeImage(from payload: String?) -> NSImage? {
        guard let payload,
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct PendingPairingRequest: Equatable, Identifiable {
    var id: String { request.phoneIdentity.id }
    var request: PairingRequest
    var remoteEndpoint: String?
    var receivedAt: Date
}

struct SessionAuditStore {
    private var url: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL
            .appendingPathComponent("Apperture", isDirectory: true)
            .appendingPathComponent("SessionAudit.json", isDirectory: false)
    }

    func loadPruningExpiredRecords(now: Date = Date()) -> [SessionAuditRecord] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -PairingConstants.auditRetentionDays,
            to: now
        ) ?? now

        let records = load().filter { $0.startedAt >= cutoff }
        save(records)
        return records
    }

    func load() -> [SessionAuditRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder.apperture.decode([SessionAuditRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    func upsert(_ record: SessionAuditRecord) {
        var records = load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        save(records)
    }

    func append(_ selection: SessionWindowSelection, to sessionID: String) {
        var records = load()
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else { return }
        records[index].selectedWindows.append(selection)
        save(records)
    }

    func endSession(_ sessionID: String, reason: String?) {
        var records = load()
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else { return }
        records[index].endedAt = Date()
        records[index].disconnectReason = reason
        save(records)
    }

    private func save(_ records: [SessionAuditRecord]) {
        guard let data = try? JSONEncoder.apperture.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }
}
