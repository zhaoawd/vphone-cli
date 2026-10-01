import Foundation
import Testing
@testable import VPhoneCore
@testable import VPhoneLaunchpadKit

/// Run state from `ps` text, the runtime record and process start times.
/// The reader's only inputs are the process list and the two injected
/// lookups below; it has no lock or `lsof` dependency to call.
struct RunStateTests {
    private let machine = VPhoneLaunchpadMachinePath(libraryRoot: "/launchpad-fixture/lib", name: "alpha")
    private let recordTime = Date(timeIntervalSince1970: 1_800_000_000)

    private func processList(bootPID: Int32? = nil, extra: String = "") -> String {
        var lines = [
            "    1 /sbin/launchd",
            "  321 /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad",
            // Mentions the path, but not as `--config`: not a boot process.
            "  322 /usr/bin/tail -f /launchpad-fixture/lib/alpha/config.plist",
            // A boot process of another machine whose name extends this one.
            "  323 /x/vphone-cli.app/Contents/MacOS/vphone-vm --config /launchpad-fixture/lib/alpha-2/config.plist",
        ]
        if let bootPID {
            lines.append("  \(bootPID) /x/vphone-cli.app/Contents/MacOS/vphone-vm --config /launchpad-fixture/lib/alpha/config.plist --vphoned-bin /x/vphoned")
        }
        if !extra.isEmpty {
            lines.append(extra)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func record(_ operation: String, pid: Int32) -> VPhoneVMRuntimeState {
        VPhoneVMRuntimeState(bundleIdentifier: "id", bundlePath: machine.url.path, pid: pid,
                             instanceID: "instance-\(pid)", startedAt: recordTime, operation: operation)
    }

    private func reader(
        record: VPhoneVMRuntimeState?,
        identities: [Int32: VPhoneProcessIdentity] = [:],
        recordReads: RecordReads? = nil
    ) -> VPhoneLaunchpadRunStateReader {
        VPhoneLaunchpadRunStateReader(
            readRecord: { url in
                recordReads?.append(url.path)
                return record
            },
            identity: { identities[$0] }
        )
    }

    private func identity(_ pid: Int32, startedAt offset: TimeInterval, zombie: Bool = false) -> VPhoneProcessIdentity {
        VPhoneProcessIdentity(pid: pid, startedAt: recordTime.timeIntervalSince1970 + offset, uid: 501, isZombie: zombie)
    }

    @Test func stoppedWithoutBootProcessOrRecord() {
        #expect(reader(record: nil).state(of: machine, processList: processList()) == .stopped)
    }

    @Test func runningFromBootProcessAlone() {
        #expect(reader(record: nil).state(of: machine, processList: processList(bootPID: 4242)) == .running(instanceID: nil))
    }

    @Test func runningWithMatchingBootRecord() {
        let state = reader(record: record(VPhoneVMOperation.boot, pid: 4242))
            .state(of: machine, processList: processList(bootPID: 4242))
        #expect(state == .running(instanceID: "instance-4242"))
    }

    @Test func dfuWithMatchingDFURecord() {
        let state = reader(record: record(VPhoneVMOperation.dfu, pid: 4242))
            .state(of: machine, processList: processList(bootPID: 4242))
        #expect(state == .dfu(instanceID: "instance-4242"))
    }

    /// A record from an earlier boot names a pid that now belongs to an
    /// unrelated process: the boot process found in `ps` wins and no instance
    /// is claimed.
    @Test func staleBootRecordDoesNotNameTheRunningInstance() {
        let state = reader(record: record(VPhoneVMOperation.boot, pid: 999), identities: [999: identity(999, startedAt: 50)])
            .state(of: machine, processList: processList(bootPID: 4242, extra: "  999 /usr/bin/other"))
        #expect(state == .running(instanceID: nil))
    }

    /// A boot record whose pid is alive but is not a boot process of this
    /// machine (pid reuse) does not make the machine run.
    @Test func staleBootRecordWithReusedPIDIsStopped() {
        let state = reader(record: record(VPhoneVMOperation.boot, pid: 999), identities: [999: identity(999, startedAt: -10)])
            .state(of: machine, processList: processList(extra: "  999 /usr/bin/other"))
        #expect(state == .stopped)
    }

    @Test func busyWhileShortOperationHolderLives() {
        let state = reader(record: record(VPhoneVMOperation.export, pid: 777), identities: [777: identity(777, startedAt: -5)])
            .state(of: machine, processList: processList())
        #expect(state == .busy(operation: "export"))
    }

    /// ISO 8601 drops the fraction of a second from the record time.
    @Test func busyToleratesRecordTimeTruncation() {
        let state = reader(record: record(VPhoneVMOperation.config, pid: 777), identities: [777: identity(777, startedAt: 0.7)])
            .state(of: machine, processList: processList())
        #expect(state == .busy(operation: "config"))
    }

    @Test func shortOperationRecordWithReusedPIDIsStopped() {
        let state = reader(record: record(VPhoneVMOperation.export, pid: 777), identities: [777: identity(777, startedAt: 30)])
            .state(of: machine, processList: processList())
        #expect(state == .stopped)
    }

    @Test func shortOperationRecordWithExitedHolderIsStopped() {
        #expect(reader(record: record(VPhoneVMOperation.delete, pid: 777)).state(of: machine, processList: processList()) == .stopped)
        let zombie = reader(record: record(VPhoneVMOperation.delete, pid: 777), identities: [777: identity(777, startedAt: -5, zombie: true)])
        #expect(zombie.state(of: machine, processList: processList()) == .stopped)
    }

    @Test func eachMachineReadsItsOwnRecordOnce() {
        let reads = RecordReads()
        let other = VPhoneLaunchpadMachinePath(libraryRoot: "/launchpad-fixture/lib", name: "alpha-2")
        let states = reader(record: nil, recordReads: reads)
            .states(processList: processList(), machines: [machine, other])
        #expect(states[machine] == .stopped)
        #expect(states[other] == .running(instanceID: nil))
        #expect(reads.paths.sorted() == [machine.url.path, other.url.path].sorted())
    }

    @Test func liveProcessListParses() throws {
        let list = try #require(VPhoneLaunchpadRunStateReader.processList())
        #expect(list.contains("\(getpid()) "))
    }
}

/// Paths the reader asked a runtime record for.
final class RecordReads: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ path: String) {
        lock.withLock { storage.append(path) }
    }

    var paths: [String] {
        lock.withLock { storage }
    }
}
