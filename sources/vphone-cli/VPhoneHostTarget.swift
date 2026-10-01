import Foundation
import VPhoneCore

// MARK: - Target Identity

/// The VM process that owns one `vphone.sock`. A client that names a target
/// in a request is refused before any command runs when the socket belongs to
/// another VM, or to a later boot of the same VM.
struct VPhoneHostTarget: Equatable {
    /// VM bundle directory name, as `vphone-cli vm` commands use it.
    let vm: String
    /// VM lock instance ID; a new boot writes a new one.
    let instanceID: String
    let pid: Int32
    /// Kernel process start time (`p_starttime`), seconds since the epoch.
    let processStartedAt: Double?

    init(vm: String, instanceID: String, pid: Int32, processStartedAt: Double?) {
        self.vm = vm
        self.instanceID = instanceID
        self.pid = pid
        self.processStartedAt = processStartedAt
    }

    /// The running VM process, from its held VM lock.
    init(lock: VPhoneVMRuntimeState) {
        self.init(vm: URL(fileURLWithPath: lock.bundlePath).lastPathComponent,
                  instanceID: lock.instanceID, pid: lock.pid,
                  processStartedAt: VPhoneProcessInfo.identity(of: lock.pid)?.startedAt)
    }

    var fields: [String: Any] {
        var fields: [String: Any] = ["vm": vm, "instance_id": instanceID, "pid": Int(pid)]
        if let processStartedAt { fields["process_started_at"] = processStartedAt }
        return fields
    }

    enum Check: Equatable {
        case match
        case invalid
        case mismatch
    }

    /// Checks an optional request `target` object. Every field it carries
    /// must match; unknown keys and wrong types are invalid.
    static func check(_ value: Any?, against target: VPhoneHostTarget?) -> Check {
        guard let value else { return .match }
        guard let expected = value as? [String: Any], !expected.isEmpty,
              Set(expected.keys).isSubset(of: ["vm", "instance_id", "pid", "process_started_at"])
        else { return .invalid }
        for key in ["vm", "instance_id"] where expected[key] != nil {
            guard let text = expected[key] as? String, !text.isEmpty else { return .invalid }
        }
        for key in ["pid", "process_started_at"] where expected[key] != nil {
            guard let number = expected[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return .invalid }
        }
        // A socket without a recorded identity cannot confirm any target.
        guard let target else { return .mismatch }
        if let vm = expected["vm"] as? String, vm != target.vm { return .mismatch }
        if let id = expected["instance_id"] as? String, id != target.instanceID { return .mismatch }
        if let pid = expected["pid"] as? NSNumber, pid.int64Value != Int64(target.pid) || pid.doubleValue != Double(target.pid) {
            return .mismatch
        }
        if let started = expected["process_started_at"] as? NSNumber,
           target.processStartedAt.map({ abs($0 - started.doubleValue) > 0.000_001 }) ?? true {
            return .mismatch
        }
        return .match
    }
}
