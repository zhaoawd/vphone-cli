import Foundation
import VPhoneCore

public typealias VPhoneLaunchpadMachineBinding = VPhoneMachineBinding

extension VPhoneMachineBinding {
    public static func snapshot(_ machine: VPhoneLaunchpadMachinePath) throws -> Snapshot? { try snapshot(machine.url) }
    static func snapshot(_ machine: VPhoneLaunchpadMachinePath, afterRead: () throws -> Void) throws -> Snapshot? {
        try snapshot(machine.url, afterRead: afterRead)
    }
    public static func load(_ machine: VPhoneLaunchpadMachinePath) -> Read { load(machine.url) }
    public static func url(for machine: VPhoneLaunchpadMachinePath, snapshot name: String) -> URL? {
        url(for: machine.url, snapshot: name)
    }
    public static func load(_ machine: VPhoneLaunchpadMachinePath, snapshot name: String) -> VPhoneMachineBinding? {
        load(machine.url, snapshot: name)
    }
    public func save(to machine: VPhoneLaunchpadMachinePath, snapshot name: String) throws {
        try save(to: machine.url, snapshot: name)
    }
}
extension VPhoneMachineBinding.Snapshot {
    public func matches(_ machine: VPhoneLaunchpadMachinePath) -> Bool { matches(machine.url) }
}
