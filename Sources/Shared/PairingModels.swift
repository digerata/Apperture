import CryptoKit
import Foundation
import Network
import Security

enum AppertureDeviceKind: String, Codable, Equatable {
    case iPhone
    case iPad
    case mac
    case unknown

    var genericDisplayName: String {
        switch self {
        case .iPhone:
            return "iPhone"
        case .iPad:
            return "iPad"
        case .mac:
            return "Mac"
        case .unknown:
            return "Device"
        }
    }

    var defaultSymbolName: String {
        switch self {
        case .iPhone:
            return "iphone"
        case .iPad:
            return "ipad"
        case .mac:
            return "macbook"
        case .unknown:
            return "questionmark.app"
        }
    }
}

enum PairingConstants {
    static let protocolVersion = 1
    static let offerLifetimeSeconds: TimeInterval = 120
    static let auditRetentionDays = 30
}

struct LocalDeviceIdentity: Codable, Equatable {
    var id: String
    var displayName: String
    var kind: AppertureDeviceKind
    var symbolName: String

    init(
        id: String = UUID().uuidString,
        displayName: String,
        kind: AppertureDeviceKind,
        symbolName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.symbolName = symbolName ?? kind.defaultSymbolName
    }
}

struct PairingOffer: Codable, Equatable, Identifiable {
    var version: Int
    var id: String
    var macDeviceID: String
    var macDisplayName: String
    var macHostName: String
    var macSymbolName: String
    var endpointHints: [String]
    var port: UInt16
    var secret: String
    var createdAt: Date
    var expiresAt: Date

    init(
        macIdentity: LocalDeviceIdentity,
        hostName: String,
        endpointHints: [String],
        port: UInt16,
        now: Date = Date()
    ) {
        self.version = PairingConstants.protocolVersion
        self.id = PairingCrypto.randomBase64URL(byteCount: 8)
        self.macDeviceID = macIdentity.id
        self.macDisplayName = macIdentity.displayName
        self.macHostName = hostName
        self.macSymbolName = macIdentity.symbolName
        self.endpointHints = endpointHints
        self.port = port
        self.secret = PairingCrypto.randomBase64URL(byteCount: 32)
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(PairingConstants.offerLifetimeSeconds)
    }

    init(
        version: Int,
        id: String,
        macDeviceID: String,
        macDisplayName: String,
        macHostName: String,
        macSymbolName: String,
        endpointHints: [String],
        port: UInt16,
        secret: String,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.version = version
        self.id = id
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.macHostName = macHostName
        self.macSymbolName = macSymbolName
        self.endpointHints = endpointHints
        self.port = port
        self.secret = secret
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }

    var qrPayload: String? {
        var components = URLComponents()
        components.scheme = "apperture"
        components.host = "p"
        components.queryItems = [
            URLQueryItem(name: "o", value: id),
            URLQueryItem(name: "s", value: secret),
            URLQueryItem(name: "e", value: endpointHints.first ?? ""),
            URLQueryItem(name: "x", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return components.string
    }

    static func decodeQRCodePayload(_ payload: String) -> PairingOffer? {
        guard let components = URLComponents(string: payload),
              components.scheme == "apperture" else {
            return nil
        }

        if components.host == "p",
           let offerID = components.queryItems?.first(where: { $0.name == "o" })?.value,
           let secret = components.queryItems?.first(where: { $0.name == "s" })?.value,
           let endpoint = components.queryItems?.first(where: { $0.name == "e" })?.value,
           let expiresAtText = components.queryItems?.first(where: { $0.name == "x" })?.value,
           let expiresAtTimestamp = TimeInterval(expiresAtText) {
            let expiresAt = Date(timeIntervalSince1970: expiresAtTimestamp)
            return PairingOffer(
                version: PairingConstants.protocolVersion,
                id: offerID,
                macDeviceID: "",
                macDisplayName: "Mac",
                macHostName: "",
                macSymbolName: AppertureDeviceKind.mac.defaultSymbolName,
                endpointHints: endpoint.isEmpty ? [] : [endpoint],
                port: RemoteFrameStreamConfiguration.tcpPort,
                secret: secret,
                createdAt: expiresAt.addingTimeInterval(-PairingConstants.offerLifetimeSeconds),
                expiresAt: expiresAt
            )
        }

        if components.host == "p",
           let encodedPayload = components.queryItems?.first(where: { $0.name == "d" })?.value,
           let data = PairingCrypto.base64URLDecode(encodedPayload),
           let compactPayload = try? JSONDecoder.apperture.decode(CompactQRCodePayload.self, from: data) {
            return compactPayload.offer
        }

        guard components.host == "pair",
              let encodedPayload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              let data = PairingCrypto.base64URLDecode(encodedPayload) else {
            return nil
        }

        return try? JSONDecoder.apperture.decode(PairingOffer.self, from: data)
    }

    private struct CompactQRCodePayload: Codable {
        var v: Int
        var o: String
        var m: String
        var n: String
        var h: String
        var y: String
        var e: String
        var p: UInt16
        var s: String
        var c: TimeInterval
        var x: TimeInterval

        init(offer: PairingOffer) {
            self.v = offer.version
            self.o = offer.id
            self.m = offer.macDeviceID
            self.n = offer.macDisplayName
            self.h = offer.macHostName
            self.y = offer.macSymbolName
            self.e = offer.endpointHints.first ?? ""
            self.p = offer.port
            self.s = offer.secret
            self.c = offer.createdAt.timeIntervalSince1970
            self.x = offer.expiresAt.timeIntervalSince1970
        }

        var offer: PairingOffer {
            PairingOffer(
                version: v,
                id: o,
                macDeviceID: m,
                macDisplayName: n,
                macHostName: h,
                macSymbolName: y,
                endpointHints: e.isEmpty ? [] : [e],
                port: p,
                secret: s,
                createdAt: Date(timeIntervalSince1970: c),
                expiresAt: Date(timeIntervalSince1970: x)
            )
        }
    }
}

struct PairingHostProfile: Codable, Equatable {
    var macDeviceID: String
    var macDisplayName: String
    var macHostName: String
    var macSymbolName: String
    var endpointHints: [String]
    var port: UInt16

    init(offer: PairingOffer) {
        self.macDeviceID = offer.macDeviceID
        self.macDisplayName = offer.macDisplayName
        self.macHostName = offer.macHostName
        self.macSymbolName = offer.macSymbolName
        self.endpointHints = offer.endpointHints
        self.port = offer.port
    }
}

struct PairingRequest: Codable, Equatable {
    var offerID: String
    var phoneIdentity: LocalDeviceIdentity
    var requestedAt: Date
    var proof: String

    init(offer: PairingOffer, phoneIdentity: LocalDeviceIdentity, requestedAt: Date = Date()) {
        self.offerID = offer.id
        self.phoneIdentity = phoneIdentity
        self.requestedAt = requestedAt
        self.proof = PairingCrypto.proof(
            secret: offer.secret,
            message: Self.proofMessage(offerID: offer.id, phoneID: phoneIdentity.id)
        )
    }

    func hasValidProof(for offer: PairingOffer) -> Bool {
        PairingCrypto.constantTimeEqual(
            proof,
            PairingCrypto.proof(
                secret: offer.secret,
                message: Self.proofMessage(offerID: offer.id, phoneID: phoneIdentity.id)
            )
        )
    }

    private static func proofMessage(offerID: String, phoneID: String) -> String {
        "pairing-request|\(offerID)|\(phoneID)"
    }
}

struct PairingResponse: Codable, Equatable {
    enum Status: String, Codable {
        case accepted
        case rejected
        case expired
    }

    var status: Status
    var pairedDevice: PairedDevice?
    var hostProfile: PairingHostProfile?
    var message: String?

    static func accepted(_ device: PairedDevice, hostProfile: PairingHostProfile? = nil) -> PairingResponse {
        PairingResponse(status: .accepted, pairedDevice: device, hostProfile: hostProfile, message: nil)
    }

    static func rejected(_ message: String) -> PairingResponse {
        PairingResponse(status: .rejected, pairedDevice: nil, hostProfile: nil, message: message)
    }
}

struct PairingAuthStatus: Codable, Equatable {
    enum Status: String, Codable {
        case accepted
        case rejected
    }

    var status: Status
    var message: String?

    static let accepted = PairingAuthStatus(status: .accepted, message: nil)

    static func rejected(_ message: String) -> PairingAuthStatus {
        PairingAuthStatus(status: .rejected, message: message)
    }
}

struct PairedDevice: Codable, Equatable, Identifiable {
    var id: String
    var peerDeviceID: String
    var displayName: String
    var kind: AppertureDeviceKind
    var symbolName: String
    var sharedSecret: String
    var pairedAt: Date
    var lastSeenAt: Date?
    var lastEndpoint: String?
    var endpointHints: [String]
    var isRevoked: Bool

    init(
        id: String = UUID().uuidString,
        peerDeviceID: String,
        displayName: String,
        kind: AppertureDeviceKind,
        symbolName: String? = nil,
        sharedSecret: String,
        pairedAt: Date = Date(),
        lastSeenAt: Date? = nil,
        lastEndpoint: String? = nil,
        endpointHints: [String] = [],
        isRevoked: Bool = false
    ) {
        self.id = id
        self.peerDeviceID = peerDeviceID
        self.displayName = displayName
        self.kind = kind
        self.symbolName = symbolName ?? kind.defaultSymbolName
        self.sharedSecret = sharedSecret
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.lastEndpoint = lastEndpoint
        self.endpointHints = endpointHints
        self.isRevoked = isRevoked
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case peerDeviceID
        case displayName
        case kind
        case symbolName
        case sharedSecret
        case pairedAt
        case lastSeenAt
        case lastEndpoint
        case endpointHints
        case isRevoked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        peerDeviceID = try container.decode(String.self, forKey: .peerDeviceID)
        displayName = try container.decode(String.self, forKey: .displayName)
        kind = try container.decode(AppertureDeviceKind.self, forKey: .kind)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        sharedSecret = try container.decode(String.self, forKey: .sharedSecret)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        lastEndpoint = try container.decodeIfPresent(String.self, forKey: .lastEndpoint)
        endpointHints = try container.decodeIfPresent([String].self, forKey: .endpointHints)
            ?? lastEndpoint.map { [$0] }
            ?? []
        isRevoked = try container.decode(Bool.self, forKey: .isRevoked)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(peerDeviceID, forKey: .peerDeviceID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(sharedSecret, forKey: .sharedSecret)
        try container.encode(pairedAt, forKey: .pairedAt)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try container.encodeIfPresent(lastEndpoint, forKey: .lastEndpoint)
        try container.encode(endpointHints, forKey: .endpointHints)
        try container.encode(isRevoked, forKey: .isRevoked)
    }
}

struct PairingAuthRequest: Codable, Equatable {
    var pairID: String
    var peerDeviceID: String
    var nonce: String
    var proof: String

    init(pairID: String, peerDeviceID: String, sharedSecret: String, nonce: String = PairingCrypto.randomBase64URL(byteCount: 16)) {
        self.pairID = pairID
        self.peerDeviceID = peerDeviceID
        self.nonce = nonce
        self.proof = PairingCrypto.proof(
            secret: sharedSecret,
            message: Self.proofMessage(pairID: pairID, peerDeviceID: peerDeviceID, nonce: nonce)
        )
    }

    func hasValidProof(sharedSecret: String) -> Bool {
        PairingCrypto.constantTimeEqual(
            proof,
            PairingCrypto.proof(
                secret: sharedSecret,
                message: Self.proofMessage(pairID: pairID, peerDeviceID: peerDeviceID, nonce: nonce)
            )
        )
    }

    private static func proofMessage(pairID: String, peerDeviceID: String, nonce: String) -> String {
        "pairing-auth|\(pairID)|\(peerDeviceID)|\(nonce)"
    }
}

#if DEBUG
enum DevelopmentPairing {
    static let simulatorPairID = "debug-ios-simulator"
    static let simulatorSharedSecret = "debug-ios-simulator-local-pairing-v1"

    static func simulatorDevice(peerDeviceID: String) -> PairedDevice {
        PairedDevice(
            id: simulatorPairID,
            peerDeviceID: peerDeviceID,
            displayName: "iOS Simulator",
            kind: .iPhone,
            sharedSecret: simulatorSharedSecret,
            pairedAt: Date(),
            isRevoked: false
        )
    }

    static func isValidSimulatorAuthRequest(_ request: PairingAuthRequest) -> Bool {
        request.pairID == simulatorPairID &&
            request.hasValidProof(sharedSecret: simulatorSharedSecret)
    }
}
#endif

struct RemoteClientEnvelope: Codable, Equatable {
    enum Kind: String, Codable {
        case pairingRequest
        case authRequest
        case control
        case clipboard
    }

    var kind: Kind
    var pairingRequest: PairingRequest?
    var authRequest: PairingAuthRequest?
    var control: RemoteControlMessage?
    var clipboard: RemoteClipboardMessage?

    static func pairingRequest(_ request: PairingRequest) -> RemoteClientEnvelope {
        RemoteClientEnvelope(kind: .pairingRequest, pairingRequest: request, authRequest: nil, control: nil, clipboard: nil)
    }

    static func authRequest(_ request: PairingAuthRequest) -> RemoteClientEnvelope {
        RemoteClientEnvelope(kind: .authRequest, pairingRequest: nil, authRequest: request, control: nil, clipboard: nil)
    }

    static func control(_ message: RemoteControlMessage) -> RemoteClientEnvelope {
        RemoteClientEnvelope(kind: .control, pairingRequest: nil, authRequest: nil, control: message, clipboard: nil)
    }

    static func clipboard(_ message: RemoteClipboardMessage) -> RemoteClientEnvelope {
        RemoteClientEnvelope(kind: .clipboard, pairingRequest: nil, authRequest: nil, control: nil, clipboard: message)
    }
}

struct SessionAuditRecord: Codable, Equatable, Identifiable {
    enum NetworkKind: String, Codable {
        case localNetwork
        case tailnet
        case privateNetwork
        case loopback
        case unknown
    }

    var id: String
    var pairedDeviceID: String
    var pairedDeviceName: String
    var startedAt: Date
    var endedAt: Date?
    var networkKind: NetworkKind
    var remoteAddress: String?
    var selectedWindows: [SessionWindowSelection]
    var disconnectReason: String?

    init(
        id: String = UUID().uuidString,
        pairedDeviceID: String,
        pairedDeviceName: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        networkKind: NetworkKind,
        remoteAddress: String?,
        selectedWindows: [SessionWindowSelection] = [],
        disconnectReason: String? = nil
    ) {
        self.id = id
        self.pairedDeviceID = pairedDeviceID
        self.pairedDeviceName = pairedDeviceName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.networkKind = networkKind
        self.remoteAddress = remoteAddress
        self.selectedWindows = selectedWindows
        self.disconnectReason = disconnectReason
    }
}

struct SessionWindowSelection: Codable, Equatable {
    var appName: String
    var windowTitle: String
    var selectedAt: Date
}

enum PairingCrypto {
    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func proof(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return base64URLEncode(Data(authenticationCode))
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsData = base64URLDecode(lhs),
              let rhsData = base64URLDecode(rhs),
              lhsData.count == rhsData.count else {
            return false
        }

        return zip(lhsData, rhsData).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        return Data(base64Encoded: base64)
    }
}

enum PrivateNetworkClassifier {
    static func networkKind(for endpoint: String?) -> SessionAuditRecord.NetworkKind {
        guard let endpoint else { return .unknown }
        let lowercasedEndpoint = endpoint.lowercased()

        if lowercasedEndpoint.contains("localhost") || lowercasedEndpoint.contains("::1") {
            return .loopback
        }

        let host = endpoint
            .split(separator: ":")
            .first
            .map(String.init) ?? endpoint

        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return .loopback
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
                return .privateNetwork
            }
            return .unknown
        }

        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return .tailnet
        }

        if octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254) {
            return .localNetwork
        }

        return .unknown
    }

    static func isAllowedPrivateEndpoint(_ endpoint: String?) -> Bool {
        switch networkKind(for: endpoint) {
        case .localNetwork, .tailnet, .privateNetwork, .loopback:
            return true
        case .unknown:
            return false
        }
    }
}

extension JSONEncoder {
    static var apperture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var apperture: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
