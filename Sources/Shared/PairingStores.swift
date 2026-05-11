import Foundation
import Security

enum PairingStoreError: Error {
    case encodingFailed
    case decodingFailed
    case keychain(OSStatus)
}

struct PairingKeychainStore<Value: Codable> {
    var service: String
    var account: String

    func load() throws -> Value? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw PairingStoreError.keychain(status)
        }

        guard let data = item as? Data else {
            throw PairingStoreError.decodingFailed
        }

        do {
            return try JSONDecoder.apperture.decode(Value.self, from: data)
        } catch {
            throw PairingStoreError.decodingFailed
        }
    }

    func save(_ value: Value) throws {
        guard let data = try? JSONEncoder.apperture.encode(value) else {
            throw PairingStoreError.encodingFailed
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw PairingStoreError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PairingStoreError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct DeviceIdentityStore {
    private let store = PairingKeychainStore<LocalDeviceIdentity>(
        service: "com.landmk1.apperture.pairing",
        account: "local-device-identity"
    )

    func loadOrCreate(displayName: String, kind: AppertureDeviceKind) -> LocalDeviceIdentity {
        if let identity = try? store.load() {
            let refreshedIdentity = refreshedIdentity(identity, displayName: displayName, kind: kind)
            if refreshedIdentity != identity {
                try? store.save(refreshedIdentity)
            }
            return refreshedIdentity
        }

        let identity = LocalDeviceIdentity(displayName: displayName, kind: kind)
        try? store.save(identity)
        return identity
    }

    private func refreshedIdentity(
        _ identity: LocalDeviceIdentity,
        displayName: String,
        kind: AppertureDeviceKind
    ) -> LocalDeviceIdentity {
        let candidateName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateName.isEmpty else { return identity }

        let storedNameIsGeneric = identity.displayName == identity.kind.genericDisplayName
        let candidateNameIsGeneric = candidateName == kind.genericDisplayName
        let shouldUpdateName = identity.displayName != candidateName && (!candidateNameIsGeneric || storedNameIsGeneric)
        let shouldUpdateKind = identity.kind != kind

        guard shouldUpdateName || shouldUpdateKind else { return identity }

        return LocalDeviceIdentity(
            id: identity.id,
            displayName: shouldUpdateName ? candidateName : identity.displayName,
            kind: kind,
            symbolName: kind.defaultSymbolName
        )
    }
}

struct PairedDeviceStore {
    private let store = PairingKeychainStore<[PairedDevice]>(
        service: "com.landmk1.apperture.pairing",
        account: "paired-devices"
    )

    func load() -> [PairedDevice] {
        (try? store.load()) ?? []
    }

    func save(_ devices: [PairedDevice]) {
        try? store.save(devices)
    }

    func upsert(_ device: PairedDevice) {
        var devices = load()
        devices.removeAll { $0.id == device.id || $0.peerDeviceID == device.peerDeviceID }
        devices.append(device)
        save(devices)
    }

    func revoke(_ deviceID: String) {
        let devices = load().map { device in
            guard device.id == deviceID || device.peerDeviceID == deviceID else { return device }
            var revoked = device
            revoked.isRevoked = true
            return revoked
        }
        save(devices)
    }
}
