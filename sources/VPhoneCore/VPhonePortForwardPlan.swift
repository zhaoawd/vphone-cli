import Foundation

/// A host-side forwarding plan. Parsing and validation open no listener and
/// change no VM/guest configuration; the network runtime must realize it.
public struct VPhonePortForwardPlan: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum TransportProtocol: String, Codable, Sendable, CaseIterable { case tcp, udp }
    public enum Error: Swift.Error, Equatable {
        case invalidInput(String)
        case duplicateListener(String)
        case unsupportedMode(String)
    }

    public let transport: TransportProtocol
    public let hostAddress: String?
    public let hostPort: Int
    public let guestPort: Int

    private enum CodingKeys: String, CodingKey {
        case transport = "protocol"
        case hostAddress, hostPort, guestPort
    }

    public init(transport: TransportProtocol = .tcp, hostAddress: String? = nil, hostPort: Int, guestPort: Int) {
        self.transport = transport
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    public var listenAddress: String { hostAddress ?? "127.0.0.1" }
    public var description: String { "\(transport.rawValue):\(listenAddress):\(hostPort):\(guestPort)" }

    /// [tcp|udp:][IPv4-address:]host-port:guest-port. LAN/wildcard addresses
    /// require an explicit address; omission always means IPv4 loopback.
    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 128 else { throw Error.invalidInput(text) }
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var transport = TransportProtocol.tcp
        if let first = parts.first, let named = TransportProtocol(rawValue: first.lowercased()) {
            transport = named
            parts.removeFirst()
        }
        var hostAddress: String?
        if parts.count == 3 {
            guard let address = address(parts[0]) else { throw Error.invalidInput(text) }
            hostAddress = address
            parts.removeFirst()
        }
        guard parts.count == 2, let hostPort = port(parts[0]), let guestPort = port(parts[1]) else { throw Error.invalidInput(text) }
        return Self(transport: transport, hostAddress: hostAddress, hostPort: hostPort, guestPort: guestPort)
    }

    /// Also validate decoded plans before use. A wildcard overlaps every
    /// address on the same protocol/port; TCP and UDP are distinct listeners.
    public static func validate(_ plans: [Self], mode: String) throws -> [Self] {
        guard !plans.isEmpty else { return plans }
        guard mode == "nat" || mode == "tunnel" else { throw Error.unsupportedMode(mode) }
        var seen: [Self] = []
        for plan in plans {
            guard (1...65535).contains(plan.hostPort), (1...65535).contains(plan.guestPort),
                  plan.hostAddress.map({ address($0) == $0 }) ?? true else { throw Error.invalidInput(plan.description) }
            guard !seen.contains(where: { other in
                other.transport == plan.transport && other.hostPort == plan.hostPort
                    && (other.listenAddress == plan.listenAddress || other.listenAddress == "0.0.0.0" || plan.listenAddress == "0.0.0.0")
            }) else { throw Error.duplicateListener("\(plan.transport.rawValue):\(plan.hostPort)") }
            seen.append(plan)
        }
        return plans
    }

    private static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    private static func address(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [String] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt8(part) else { return nil }
            values.append(String(value))
        }
        return values.joined(separator: ".")
    }
}
