import Darwin
import Foundation
import VPhoneCore

// MARK: - Run state

/// What Launchpad shows for a machine. Derived from the process list, the
/// bundle's runtime record and the kernel's process start times only.
///
/// Launchpad never takes or probes a bundle lock (`VPhoneVMLock`,
/// `VPhoneVMLockProbe`, `isRunLockHeld`): a probe briefly holds the same
/// `flock` a real operation needs, and polling every few seconds would make
/// those operations fail as busy more often. It does not use `lsof` either:
/// the disk image is held by the Virtualization.framework helper, not by the
/// process that owns the VM (see `VPhoneBootProcessLocator`).
public enum VPhoneLaunchpadRunState: Hashable, Sendable {
    case stopped
    /// A `vphone-vm`/`vphone-cli --config <bundle>/config.plist` process
    /// runs. `instanceID` is set when the runtime record names one of its
    /// PIDs with a boot operation.
    case running(instanceID: String?)
    /// As `running`, and the runtime record says the boot is a DFU boot.
    case dfu(instanceID: String)
    /// No boot process, but a live process that started no later than the
    /// runtime record wrote a short operation (`config`, `export`, ...). A
    /// hint only; the CLI refuses conflicting work itself while it holds the
    /// lock.
    case busy(operation: String)

    public var isRunning: Bool {
        switch self {
        case .running, .dfu: true
        case .stopped, .busy: false
        }
    }
}

// MARK: - Reader

public struct VPhoneLaunchpadRunStateReader: Sendable {
    /// Allowance for the runtime record's ISO 8601 time, which drops the
    /// fraction of a second: a holder that started at 10.7 s may write a
    /// record that reads back as 10 s.
    public static let recordTimeTolerance: TimeInterval = 1

    var readRecord: @Sendable (URL) -> VPhoneVMRuntimeState?
    var identity: @Sendable (pid_t) -> VPhoneProcessIdentity?

    public static let live = VPhoneLaunchpadRunStateReader(
        readRecord: { VPhoneVMRuntimeState.read(in: $0) },
        identity: { VPhoneProcessInfo.identity(of: $0) }
    )

    init(
        readRecord: @escaping @Sendable (URL) -> VPhoneVMRuntimeState?,
        identity: @escaping @Sendable (pid_t) -> VPhoneProcessIdentity?
    ) {
        self.readRecord = readRecord
        self.identity = identity
    }

    /// The state of each machine, from one `ps -axo pid=,command=` snapshot.
    public func states(
        processList: String,
        machines: [VPhoneLaunchpadMachinePath]
    ) -> [VPhoneLaunchpadMachinePath: VPhoneLaunchpadRunState] {
        var result: [VPhoneLaunchpadMachinePath: VPhoneLaunchpadRunState] = [:]
        for machine in machines {
            result[machine] = state(of: machine, processList: processList)
        }
        return result
    }

    public func state(of machine: VPhoneLaunchpadMachinePath, processList: String) -> VPhoneLaunchpadRunState {
        let bootPIDs = VPhoneBootProcessLocator.parsePIDs(processList, configURL: machine.configURL)
        let record = readRecord(machine.url)
        if !bootPIDs.isEmpty {
            // A record counts only when it names one of the boot processes:
            // it is never deleted on exit and can name a reused pid.
            guard let record, record.isBootOperation, bootPIDs.contains(record.pid) else {
                return .running(instanceID: nil)
            }
            return record.isDFUOperation ? .dfu(instanceID: record.instanceID) : .running(instanceID: record.instanceID)
        }
        guard let record, !record.isBootOperation,
              let holder = identity(record.pid), !holder.isZombie,
              holder.startedAt <= record.startedAt.timeIntervalSince1970 + Self.recordTimeTolerance
        else {
            return .stopped
        }
        return .busy(operation: record.operation)
    }

    // MARK: - Process list

    /// `ps -axo pid=,command=`, or nil when it could not run.
    public static func processList() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
