import Darwin
import Foundation

struct HostConnectionHint: Identifiable, Equatable {
    enum Kind: String {
        case tailscale
        case localNetwork
        case hostname

        var title: String {
            switch self {
            case .tailscale:
                return "Tailscale"
            case .localNetwork:
                return "LAN"
            case .hostname:
                return "Hostname"
            }
        }

        var symbolName: String {
            switch self {
            case .tailscale:
                return "point.3.connected.trianglepath.dotted"
            case .localNetwork:
                return "wifi"
            case .hostname:
                return "desktopcomputer"
            }
        }
    }

    var kind: Kind
    var host: String
    var port: UInt16

    var id: String {
        "\(kind.rawValue)-\(host)-\(port)"
    }

    var title: String {
        kind.title
    }

    var endpointText: String {
        "\(host):\(port)"
    }

    var symbolName: String {
        kind.symbolName
    }
}

final class HostNetworkAddressService {
    func connectionHints(port: UInt16) -> [HostConnectionHint] {
        let addresses = interfaceAddresses()
        var hints: [HostConnectionHint] = []

        hints.append(
            contentsOf: addresses
                .filter { Self.isTailscaleIPv4Address($0.address) }
                .prefix(2)
                .map { address in
                    HostConnectionHint(kind: .tailscale, host: address.address, port: port)
                }
        )

        hints.append(
            contentsOf: addresses
                .filter { Self.isPrivateIPv4Address($0.address) && !Self.isTailscaleIPv4Address($0.address) }
                .prefix(2)
                .map { address in
                    HostConnectionHint(kind: .localNetwork, host: address.address, port: port)
                }
        )

        if let hostname = preferredHostname() {
            hints.append(HostConnectionHint(kind: .hostname, host: hostname, port: port))
        }

        return hints
    }

    private func interfaceAddresses() -> [InterfaceAddress] {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
            return []
        }

        defer {
            freeifaddrs(addressPointer)
        }

        var addresses: [InterfaceAddress] = []
        var currentAddress: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let address = currentAddress {
            defer {
                currentAddress = address.pointee.ifa_next
            }

            let interface = address.pointee
            guard let socketAddress = interface.ifa_addr else { continue }
            guard socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let interfaceName = String(cString: interface.ifa_name)
            let addressText = String(cString: hostname)
            guard !addresses.contains(where: { $0.address == addressText }) else { continue }
            addresses.append(InterfaceAddress(name: interfaceName, address: addressText))
        }

        return addresses.sorted { lhs, rhs in
            if Self.isTailscaleIPv4Address(lhs.address) != Self.isTailscaleIPv4Address(rhs.address) {
                return Self.isTailscaleIPv4Address(lhs.address)
            }

            return lhs.name < rhs.name
        }
    }

    private func preferredHostname() -> String? {
        let candidates = [
            ProcessInfo.processInfo.hostName,
            Host.current().localizedName
        ]

        return candidates
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { hostname in
                hostname.hasSuffix(".local")
                    ? String(hostname.dropLast(".local".count))
                    : hostname
            }
            .first { !$0.isEmpty && !$0.contains(" ") }
    }

    private static func isTailscaleIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isPrivateIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }
}

private struct InterfaceAddress {
    var name: String
    var address: String
}
