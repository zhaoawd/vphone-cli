import Foundation

// MARK: - Machine path

/// A machine's library root and name. Machines in two libraries may share a
/// name, so the pair, not the name, identifies a machine.
public struct VPhoneLaunchpadMachinePath: Hashable, Sendable {
    /// A canonical root, as `VPhoneLaunchpadMachineLocations.canonical` makes it.
    public let libraryRoot: String
    public let name: String

    public init(libraryRoot: String, name: String) {
        self.libraryRoot = libraryRoot
        self.name = name
    }

    public var url: URL {
        URL(fileURLWithPath: libraryRoot, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// The bundle's `config.plist`, the path a running VM process carries as
    /// `--config`.
    public var configURL: URL {
        url.appendingPathComponent("config.plist")
    }

    public var libraryArguments: [String] {
        ["--library-root", libraryRoot]
    }
}

// MARK: - vm list / vm info

/// Mirrors `VPhoneBundleReport`, the JSON `vphone-cli vm list --json` and
/// `vm info --json` print.
public struct VPhoneLaunchpadMachine: Decodable, Hashable, Identifiable, Sendable {
    public struct Network: Decodable, Hashable, Sendable {
        public let mode: String
        public let macAddress: String
        public let bridgeInterface: String?
    }

    public struct OSVersion: Decodable, Hashable, Sendable {
        public let version: String
        public let build: String
    }

    public struct RestoreInfo: Decodable, Hashable, Sendable {
        public let ios: OSVersion
        public let cloudOS: OSVersion
        public let variant: String?
        public let device: String?

        /// The firmware variant recorded at restore time, by the local
        /// `--variant` names (`regular`, `dev`, `jb`, `exp`, `less`).
        public var firmwareName: String {
            switch variant {
            case "regular": String(localized: "Regular Firmware")
            case "dev": String(localized: "Development Firmware")
            case "jb": String(localized: "Jailbreak Firmware")
            case "exp": String(localized: "Experimental Firmware")
            case "less": String(localized: "Less Firmware")
            default: String(localized: "Unknown Firmware")
            }
        }
    }

    public let name: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let diskSizeBytes: Int64
    public let network: Network
    public let restoreInfo: RestoreInfo?
    /// Upstream's field; the local `VPhoneBundleReport` does not write it, so
    /// it decodes as nil.
    public let customFirmwareInstalled: Bool?
    public let udid: String?
    /// The library `vm list` was run on. Not part of the JSON.
    public var libraryRoot = ""

    private enum CodingKeys: String, CodingKey {
        case name, cpuCount, memoryMB, diskSizeBytes, network, restoreInfo, customFirmwareInstalled, udid
    }

    public var path: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: libraryRoot, name: name)
    }

    public var id: VPhoneLaunchpadMachinePath {
        path
    }

    /// The table's iOS sort key; a machine not yet restored sorts first.
    public var iosVersion: String {
        restoreInfo?.ios.version ?? ""
    }

    /// `vm config --network` values: `nat`, `bridged`, `none`; `hostOnly`
    /// may appear in an older manifest.
    public var networkDescription: String {
        switch network.mode {
        case "nat": String(localized: "NAT")
        case "bridged": network.bridgeInterface.map { String(localized: "Bridged to \($0)") } ?? String(localized: "Bridged")
        case "hostOnly": String(localized: "Host only")
        default: String(localized: "None")
        }
    }

    /// Decodes `vm list --json` output and tags every machine with the
    /// library it was listed from.
    public static func decodeList(_ data: Data, libraryRoot: String) throws -> [VPhoneLaunchpadMachine] {
        var machines = try JSONDecoder().decode([VPhoneLaunchpadMachine].self, from: data)
        for index in machines.indices {
            machines[index].libraryRoot = libraryRoot
        }
        return machines
    }
}
