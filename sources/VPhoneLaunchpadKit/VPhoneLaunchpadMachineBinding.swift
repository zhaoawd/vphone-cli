import Foundation
import VPhoneCore

public typealias VPhoneLaunchpadMachineBinding = VPhoneMachineBinding

extension VPhoneMachineBinding {
    public static func snapshot(_ machine: VPhoneLaunchpadMachinePath) throws -> Snapshot? { try snapshot(machine.url) }
    static func snapshot(_ machine: VPhoneLaunchpadMachinePath, afterRead: () throws -> Void) throws -> Snapshot? {
        try snapshot(machine.url, afterRead: afterRead)
    }
    public static func load(_ machine: VPhoneLaunchpadMachinePath) -> Read { load(machine.url) }

}
extension VPhoneMachineBinding.Snapshot {
    public func matches(_ machine: VPhoneLaunchpadMachinePath) -> Bool { matches(machine.url) }
}
