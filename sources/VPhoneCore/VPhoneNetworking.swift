import Foundation
import Virtualization

// MARK: - Errors

public enum VPhoneNetworkingError: Error, Equatable {
    /// hostOnly has no native Virtualization.framework attachment.
    case hostOnlyUnsupported
    /// tunnel mode requires the userspace network runtime.
    case tunnelUnsupported
    /// A bridge interface was requested but no such interface exists on the host.
    case bridgeInterfaceNotFound(requested: String, available: [String])
    /// bridged mode was selected but the host exposes no bridgeable interfaces.
    case noBridgeInterfaces
    /// `--bridge-interface` was given without selecting bridged mode.
    case bridgeInterfaceWithoutBridgedMode
    /// An mDNS localHostName is not a valid DNS label.
    case invalidLocalHostName(String)
}

extension VPhoneNetworkingError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .hostOnlyUnsupported:
            "network mode 'hostOnly' is not supported (Virtualization.framework has no host-only attachment); use nat, bridged, or none"
        case .tunnelUnsupported:
            "network mode 'tunnel' is not supported by this runtime; use nat, bridged, or none"
        case let .bridgeInterfaceNotFound(requested, available):
            "bridge interface '\(requested)' not found; available: \(available.isEmpty ? "(none)" : available.joined(separator: ", "))"
        case .noBridgeInterfaces:
            "bridged mode requires a host interface, but none are available for bridging"
        case .bridgeInterfaceWithoutBridgedMode:
            "--bridge-interface is only valid with --network bridged"
        case let .invalidLocalHostName(name):
            "invalid mDNS host name '\(name)'; expected 1..63 ASCII letters, digits, or internal hyphens"
        }
    }
    public var errorDescription: String? { description }
}

// MARK: - Networking helpers

/// Host-side helpers for validating and realizing a VM's `NetworkConfig`.
/// Shared between config-time editing (`VPhoneBundleOps.updateConfig`) and boot-time
/// device construction so both agree on validation and interface resolution.
public enum VPhoneNetworking {
    public typealias NetworkConfig = VPhoneVirtualMachineManifest.NetworkConfig
    public typealias NetworkMode = NetworkConfig.NetworkMode

    /// Identifiers of host interfaces available for bridging (empty without the
    /// `com.apple.vm.networking` entitlement, e.g. in unsigned test binaries).
    public static func availableBridgeInterfaces() -> [String] {
        VZBridgedNetworkInterface.networkInterfaces.map(\.identifier)
    }

    /// Resolve the concrete bridge interface to persist for bridged mode.
    /// - `requested`: an explicit `--bridge-interface`, validated against the host.
    /// - `current`: the interface already stored on the bundle, kept if still present.
    /// - otherwise the first available interface is auto-picked.
    public static func resolveBridgeInterface(requested: String?, current: String?) throws -> String {
        let available = availableBridgeInterfaces()
        if let requested {
            guard available.contains(requested) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(requested: requested, available: available)
            }
            return requested
        }
        if let current, available.contains(current) {
            return current
        }
        guard let first = available.first else {
            throw VPhoneNetworkingError.noBridgeInterfaces
        }
        return first
    }

    /// The mDNS name `--mdns on` gives a VM: its name with everything but
    /// letters and digits turned into hyphens, as a DNS label allows.
    public static func localHostName(forVMName name: String) -> String {
        var label = ""
        for scalar in name.unicodeScalars {
            let allowed = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if allowed {
                label.unicodeScalars.append(scalar)
            } else if !label.hasSuffix("-") {
                label += "-"
            }
        }
        label = String(label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? "vphone" : label
    }

    /// `name`, if it is one DNS label: 1 to 63 letters, digits and hyphens,
    /// with no hyphen at either end. A trailing `.local` is dropped.
    public static func validLocalHostName(_ name: String) throws -> String {
        let label = name.lowercased().hasSuffix(".local") ? String(name.dropLast(6)) : name
        let allowed = label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        guard (1...63).contains(label.count), allowed, !label.hasPrefix("-"), !label.hasSuffix("-") else {
            throw VPhoneNetworkingError.invalidLocalHostName(name)
        }
        return label
    }

    /// Merge partial edits onto an existing config, validating the result.
    /// A nil argument leaves that field unchanged.
    public static func merge(
        into current: NetworkConfig,
        mode: NetworkMode?,
        bridgeInterface: String?
    ) throws -> NetworkConfig {
        let newMode = mode ?? current.mode
        if newMode == .hostOnly {
            throw VPhoneNetworkingError.hostOnlyUnsupported
        }
        if newMode == .tunnel {
            throw VPhoneNetworkingError.tunnelUnsupported
        }
        let newBridge: String?
        if newMode == .bridged {
            newBridge = try resolveBridgeInterface(requested: bridgeInterface, current: current.bridgeInterface)
        } else {
            if bridgeInterface != nil {
                throw VPhoneNetworkingError.bridgeInterfaceWithoutBridgedMode
            }
            newBridge = current.bridgeInterface
        }
        return current.with(mode: newMode, bridgeInterface: .some(newBridge))
    }

    /// Build the VZ network device for a config, or nil for `.off` (no NIC).
    /// The MAC is left framework-assigned; a forced MAC breaks guest networking.
    /// Throws if the config cannot be realized (missing bridge interface, hostOnly).
    public static func makeNetworkDevice(_ cfg: NetworkConfig) throws -> VZVirtioNetworkDeviceConfiguration? {
        switch cfg.mode {
        case .off:
            return nil
        case .hostOnly:
            throw VPhoneNetworkingError.hostOnlyUnsupported
        case .tunnel:
            throw VPhoneNetworkingError.tunnelUnsupported
        case .nat:
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            return net
        case .bridged:
            guard let id = cfg.bridgeInterface else {
                throw VPhoneNetworkingError.noBridgeInterfaces
            }
            guard let iface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == id }) else {
                throw VPhoneNetworkingError.bridgeInterfaceNotFound(
                    requested: id, available: availableBridgeInterfaces())
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            return net
        }
    }
}
