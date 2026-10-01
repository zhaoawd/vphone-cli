import Darwin
import Foundation
import Testing
import VPhoneCore

/// `vm create` cancelled the way Launchpad cancels it (B4 G4): SIGINT to the
/// process group whose leader is `vm create`. The real CLI runs a fresh create
/// in temporary directories; the prepare stage's script is a stand-in.
///
/// Foundation `Process` starts every child in a new process group, so the
/// signal reaches only `vm create`; the stand-in has a foreground child that
/// writes into the VM directory and a background grandchild that leaves the
/// stage's group (setpgid) and writes too.
@Suite(.serialized)
struct CreateCancellationEndToEndTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let cli = repo.appendingPathComponent(".build/debug/vphone-cli")

    /// Guest boot is unavailable in a VM, and `vm create` refuses to start there.
    static var isNestedHost: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }

    static var python: String? {
        [repo.appendingPathComponent(".venv/bin/python3").path, "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let prepareStandIn = #"""
    #!/bin/bash
    # Stand-in for scripts/fw_prepare.sh, run by vm_lock.py in the bundle.
    set -u
    out="$STANDIN_DIR"
    echo $$ > "$out/prepare.pid"
    "$STANDIN_PYTHON" - "$out/grouped.pid" "$PWD/standin-grouped-writes" <<'PY' &
    import os, signal, sys, time
    os.setpgid(0, 0)
    # A background job starts with SIGINT ignored; restore the default handler
    # the way an interactive tool would.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    open(sys.argv[1], "w").write(str(os.getpid()))
    while True:
        with open(sys.argv[2], "a") as stream:
            stream.write("w\n")
        time.sleep(0.05)
    PY
    "$STANDIN_PYTHON" -c '
    import os, sys, time
    open(sys.argv[1], "w").write(str(os.getpid()))
    while True:
        with open(sys.argv[2], "a") as stream:
            stream.write("w\n")
        time.sleep(0.05)
    ' "$out/writer.pid" "$PWD/standin-writes"
    """#

    struct Tracked {
        let label: String
        let identity: VPhoneProcessIdentity
        let group: pid_t
        var alive: Bool {
            guard let now = VPhoneProcessInfo.identity(of: identity.pid) else { return false }
            return now.startedAt == identity.startedAt && !now.isZombie
        }
    }

    @Test(.enabled(if: !isNestedHost && python != nil && FileManager.default.isExecutableFile(atPath: cli.path)))
    func sigintToTheCreateGroupEndsEveryStageProcessAndLeavesAnInterruptedCheckpoint() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("vc-cancel-\(UUID().uuidString.prefix(8))")
        let root = temp.appendingPathComponent("resources")
        let scripts = root.appendingPathComponent("scripts")
        let library = temp.appendingPathComponent("lib")
        let standIn = temp.appendingPathComponent("standin")
        for directory in [scripts, library, standIn, temp.appendingPathComponent("user")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var tracked: [Tracked] = []
        defer {
            // Never leave a stand-in behind, whatever the result.
            for process in tracked where process.alive { kill(process.identity.pid, SIGKILL) }
            for process in tracked where process.group > 1 && process.group != getpgrp() { killpg(process.group, SIGKILL) }
            try? fm.removeItem(at: temp)
        }
        try fm.copyItem(at: Self.repo.appendingPathComponent("scripts/vm_lock.py"), to: scripts.appendingPathComponent("vm_lock.py"))
        try Data("import sys\nsys.exit(0)\n".utf8).write(to: scripts.appendingPathComponent("check_python_runtime.py"))
        try Data(Self.prepareStandIn.utf8).write(to: scripts.appendingPathComponent("fw_prepare.sh"))

        let log = temp.appendingPathComponent("create.log")
        fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let create = Process()
        create.executableURL = Self.cli
        create.arguments = [
            "vm", "create", "e2e", "--library-root", library.path, "--variant", "regular",
            "--iphone-source", temp.appendingPathComponent("iphone.ipsw").path,
            "--cloudos-source", temp.appendingPathComponent("cloudos.ipsw").path,
            "--disk-size", "1", "--root-popup", "--project-root", root.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["VPHONE_ROOT"] = temp.appendingPathComponent("user").path
        environment["VPHONE_PYTHON"] = Self.python!
        environment["STANDIN_PYTHON"] = Self.python!
        environment["STANDIN_DIR"] = standIn.path
        environment.removeValue(forKey: "VPHONE_LIBRARY_ROOT")
        create.environment = environment
        create.standardInput = FileHandle.nullDevice
        create.standardOutput = output
        create.standardError = output
        try create.run()
        let leader = create.processIdentifier
        defer { if create.isRunning { kill(leader, SIGKILL); create.waitUntilExit() } }

        func pid(_ name: String) -> pid_t? {
            (try? String(contentsOf: standIn.appendingPathComponent(name), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let bundle = library.appendingPathComponent("e2e")
        let writes = bundle.appendingPathComponent("standin-writes")
        let groupedWrites = bundle.appendingPathComponent("standin-grouped-writes")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, create.isRunning,
              pid("prepare.pid") == nil || pid("writer.pid") == nil || pid("grouped.pid") == nil
                || !fm.fileExists(atPath: writes.path) || !fm.fileExists(atPath: groupedWrites.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let started = try String(contentsOf: log, encoding: .utf8)
        try #require(create.isRunning, "vm create exited before the stand-in started:\n\(started)")
        for name in ["prepare.pid", "writer.pid", "grouped.pid"] {
            guard let value = pid(name), let identity = VPhoneProcessInfo.identity(of: value) else {
                Issue.record("\(name) missing or not running:\n\(started)")
                return
            }
            tracked.append(Tracked(label: name, identity: identity, group: getpgid(value)))
        }
        // The cause: the stage child is not in vm create's process group, and
        // the grandchild has a group of its own.
        #expect(getpgid(leader) == leader)
        #expect(tracked[0].group != leader)
        #expect(tracked[2].group == tracked[2].identity.pid)

        // Launchpad's Stop Creating.
        #expect(killpg(leader, SIGINT) == 0)
        let exitDeadline = Date().addingTimeInterval(60)
        while create.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.05) }
        try #require(!create.isRunning, "vm create did not exit within 60 s of SIGINT")
        let transcript = try String(contentsOf: log, encoding: .utf8)
        #expect(create.terminationReason == .exit && create.terminationStatus == 130,
                "reason \(create.terminationReason.rawValue) status \(create.terminationStatus)\n\(transcript)")

        // No stage process outlives vm create, and nothing writes into the bundle afterwards.
        let goneDeadline = Date().addingTimeInterval(2)
        while tracked.contains(where: \.alive), Date() < goneDeadline { Thread.sleep(forTimeInterval: 0.05) }
        for process in tracked {
            #expect(!process.alive, "\(process.label) pid \(process.identity.pid) still runs after vm create exited")
            #expect(killpg(process.group, 0) == -1 && errno == ESRCH, "process group \(process.group) (\(process.label)) still has members")
        }
        let sizes = [writes, groupedWrites].map { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? -1 }
        Thread.sleep(forTimeInterval: 0.5)
        let later = [writes, groupedWrites].map { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? -1 }
        #expect(sizes == later, "the bundle is still written after vm create exited")

        // The checkpoint keeps prepare as running (overall interrupted) and no lock is held.
        let status = try VPhoneProcessRunner.runCapturing(
            Self.cli, ["vm", "create-status", "e2e", "--json", "--library-root", library.path], timeout: 30)
        let report = try JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any] ?? [:]
        let live = report["live"] as? [String: Any] ?? [:]
        #expect(report["overall_status"] as? String == "interrupted", "\(status.stdout)")
        #expect(live["create_run_in_progress"] as? Bool == false)
        #expect(live["bundle_lock_held"] as? Bool == false)
        let stages = ((report["checkpoint"] as? [String: Any])?["stages"] as? [[String: Any]]) ?? []
        let prepare = stages.first { $0["stage"] as? String == "prepare" } ?? [:]
        #expect(prepare["status"] as? String == "running")
        #expect((prepare["error"] as? String)?.contains("interrupted by SIGINT") == true, "\(prepare)")
        #expect((prepare["error"] as? String)?.contains("every stage process ended") == true, "\(prepare)")
        #expect(transcript.contains("stopped by SIGINT during prepare"), "\(transcript)")
        #expect(!VPhoneCreateCheckpointStore.isRunLockHeld(bundleURL: bundle))
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: bundle))
    }
}
