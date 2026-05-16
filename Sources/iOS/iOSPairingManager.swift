import Foundation
import PostHog
import UIKit

@MainActor
final class IOSPairingManager: ObservableObject {
    @Published private(set) var localIdentity: LocalDeviceIdentity
    @Published private(set) var pairedMacs: [PairedDevice]
    @Published private(set) var pendingOffer: PairingOffer?
    @Published private(set) var lastPairingError: String?

    private let identityStore = DeviceIdentityStore()
    private let pairedDeviceStore = PairedDeviceStore()

    init() {
        let device = UIDevice.current
        let kind: AppertureDeviceKind = device.userInterfaceIdiom == .pad ? .iPad : .iPhone
        localIdentity = identityStore.loadOrCreate(displayName: device.name, kind: kind)
        pairedMacs = pairedDeviceStore.load()
    }

    func loadPairings() {
        pairedMacs = pairedDeviceStore.load()
    }

    func beginPairing(from qrPayload: String) -> PairingRequest? {
        guard let offer = PairingOffer.decodeQRCodePayload(qrPayload) else {
            lastPairingError = "That QR code is not an Apperture pairing code."
            return nil
        }

        guard !offer.isExpired() else {
            lastPairingError = "That pairing code expired. Create a new one on the Mac."
            return nil
        }

        pendingOffer = offer
        lastPairingError = nil
        // PostHog: Track pairing initiation from QR scan
        PostHogSDK.shared.capture("ios_pairing_initiated", properties: [
            "mac_name": offer.macDisplayName,
        ])
        return PairingRequest(offer: offer, phoneIdentity: localIdentity)
    }

    func accept(_ pairedDevice: PairedDevice, hostProfile: PairingHostProfile?) {
        let endpointHints = hostProfile?.endpointHints ?? pendingOffer?.endpointHints ?? []
        let macDevice = PairedDevice(
            id: pairedDevice.id,
            peerDeviceID: hostProfile?.macDeviceID ?? pendingOffer?.macDeviceID ?? pairedDevice.peerDeviceID,
            displayName: hostProfile?.macDisplayName ?? pendingOffer?.macDisplayName ?? pairedDevice.displayName,
            kind: .mac,
            symbolName: hostProfile?.macSymbolName ?? pendingOffer?.macSymbolName ?? AppertureDeviceKind.mac.defaultSymbolName,
            sharedSecret: pendingOffer?.secret ?? pairedDevice.sharedSecret,
            pairedAt: Date(),
            lastEndpoint: endpointHints.first,
            endpointHints: endpointHints,
            isRevoked: false
        )
        pairedDeviceStore.upsert(macDevice)
        pairedMacs = pairedDeviceStore.load()
        pendingOffer = nil
        lastPairingError = nil
        // PostHog: Track successful pairing acceptance
        PostHogSDK.shared.capture("ios_pairing_accepted", properties: [
            "mac_name": macDevice.displayName,
        ])
    }

    func reject(_ message: String?) {
        pendingOffer = nil
        lastPairingError = message ?? "Pairing was not accepted on the Mac."
    }

    func forget(_ device: PairedDevice) {
        pairedDeviceStore.revoke(device.id)
        pairedMacs = pairedDeviceStore.load()
        // PostHog: Track device forgotten
        PostHogSDK.shared.capture("ios_device_forgotten", properties: [
            "mac_name": device.displayName,
        ])
    }

    func authRequest(for device: PairedDevice) -> PairingAuthRequest {
        PairingAuthRequest(
            pairID: device.id,
            peerDeviceID: localIdentity.id,
            sharedSecret: device.sharedSecret
        )
    }
}
