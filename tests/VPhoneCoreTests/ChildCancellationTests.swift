import Darwin
import Foundation
import Testing
@testable import VPhoneCore

// vm create cancellation (B4 acceptance problem 2): stage children run in
// process groups of their own, so the controller forwards SIGINT/SIGTERM and
// escalates. Stand-in children only; no VM, firmware or sudo. Signals are
// sent to the test's own children, never to the test process.

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var exits: [(Int32, Date)] = []
    func log(_ line: String) { lock.withLock { lines.append(line) } }
    func exit(_ code: Int32) { lock.withLock { exits.append((code, Date())) } }
    var logged: [String] { lock.withLock { lines } }
    var exitCodes: [Int32] { lock.withLock { exits.map(\.0) } }
    var exitTimes: [Date] { lock.withLock { exits.map(\.1) } }
}

private func controller(
    _ recorder: Recorder, toolGrace: TimeInterval = 0.5, forcedExit: TimeInterval = 60
) -> VPhoneChildCancellation {
    VPhoneChildCancellation(
        timing: .init(toolGrace: toolGrace, virtualMachineGrace: toolGrace, forcedExit: forcedExit, settleMargin: 10),
        log: { recorder.log($0) }, exitProcess: { recorder.exit($0) })
}

/// Runs `body` on another thread with `cancellation` bound, like vm create's main thread.
private final class Background<T>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    init(_ cancellation: VPhoneChildCancellation, _ body: @escaping @Sendable () throws -> T) {
        let thread = Thread { [self] in
            result = Result { try VPhoneChildCancellation.$current.withValue(cancellation) { try body() } }
            done.signal()
        }
        thread.start()
    }

    func wait(_ timeout: TimeInterval = 60) -> Result<T, Error>? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result
    }
}

private struct StandIn {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vc-cancel-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func script(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(("#!/bin/bash\nout=\"$1\"\n" + body).utf8).write(to: url)
        return url
    }

    func pid(_ name: String, timeout: TimeInterval = 20) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    func cleanup(_ identities: [VPhoneProcessIdentity]) {
        for identity in identities where alive(identity) { kill(identity.pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func alive(_ identity: VPhoneProcessIdentity) -> Bool {
    guard let now = VPhoneProcessInfo.identity(of: identity.pid) else { return false }
    return now.startedAt == identity.startedAt && !now.isZombie
}

private func runBash(_ script: URL, _ argument: URL) throws -> Int32 {
    try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/bin/bash"), [script.path, argument.path], echo: false)
}

/// Child that leaves the stage's group and ignores SIGINT; a sibling in the
/// stage's group that ignores SIGINT as background jobs of a script do.
private let treeScript = """
echo $$ > "$out/child.pid"
( trap '' INT; while :; do sleep 0.05; done ) &
echo $! > "$out/ignoring.pid"
/usr/bin/perl -e 'setpgrp(0, 0); $SIG{INT} = "IGNORE"; open(my $f, ">", $ARGV[0]); print $f $$; close $f; sleep 60' "$out/grouped.pid" &
wait
"""

@Suite struct ChildCancellationTests {
    /// The cause of B4 problem 2: a child started by Foundation `Process`
    /// leads a new process group, so `killpg(<parent pid>, SIGINT)` misses it.
    @Test func foundationProcessStartsANewProcessGroup() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(getpgid(process.processIdentifier) == process.processIdentifier)
        #expect(getpgid(process.processIdentifier) != getpgrp())
    }

    @Test func requestEndsTheWholeChildTreeIncludingOwnGroupAndIgnoringDescendants() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder)
        let standIn = try StandIn()
        var identities: [VPhoneProcessIdentity] = []
        defer { cancellation.complete(); standIn.cleanup(identities) }
        let script = try standIn.script("tree.sh", treeScript)
        let run = Background(cancellation) { try runBash(script, standIn.directory) }
        for name in ["child.pid", "ignoring.pid", "grouped.pid"] {
            let pid = try #require(standIn.pid(name), "\(name) not written")
            identities.append(try #require(VPhoneProcessInfo.identity(of: pid)))
        }
        let childGroup = getpgid(identities[0].pid)
        #expect(childGroup == identities[0].pid && childGroup != getpgrp())
        #expect(getpgid(identities[2].pid) == identities[2].pid)

        cancellation.request(signal: SIGINT)
        let result = try #require(run.wait(), "the stage's runStreaming did not return")
        #expect((try? result.get()) != 0)
        #expect(cancellation.settle())
        for identity in identities { #expect(!alive(identity), "pid \(identity.pid) survived") }
        #expect(killpg(childGroup, 0) == -1)
        #expect(recorder.logged.contains { $0.contains("sending SIGKILL") })
        #expect(recorder.exitCodes.isEmpty)
    }

    @Test func childStartedAfterTheSignalIsStoppedAtOnce() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder, toolGrace: 5)
        defer { cancellation.complete() }
        cancellation.request(signal: SIGINT)
        let start = Date()
        let code = try VPhoneChildCancellation.$current.withValue(cancellation) {
            try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/bin/sleep"), ["30"], echo: false)
        }
        #expect(code != 0)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func secondSignalKillsWithoutWaitingForTheGrace() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder, toolGrace: 60)
        let standIn = try StandIn()
        var identities: [VPhoneProcessIdentity] = []
        defer { cancellation.complete(); standIn.cleanup(identities) }
        let script = try standIn.script("ignore.sh", "trap '' INT\necho $$ > \"$out/child.pid\"\nwhile :; do sleep 0.05; done\n")
        let run = Background(cancellation) { try runBash(script, standIn.directory) }
        identities.append(try #require(standIn.pid("child.pid").flatMap(VPhoneProcessInfo.identity(of:))))
        cancellation.request(signal: SIGINT)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(alive(identities[0]), "a child that ignores SIGINT runs until the grace ends")
        let start = Date()
        cancellation.request(signal: SIGINT)
        _ = run.wait(10)
        #expect(!alive(identities[0]))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    /// The CFW driver runs as root; inside `deferring` nothing is forwarded
    /// and no early exit is taken until it returns.
    @Test func deferredChildIsNotSignalledAndTheForcedExitWaitsForIt() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder, forcedExit: 0.2)
        let standIn = try StandIn()
        defer { cancellation.complete(); standIn.cleanup([]) }
        let script = try standIn.script("root-like.sh", """
        trap 'echo int > "$out/got-int"' INT
        echo $$ > "$out/child.pid"
        for i in $(seq 1 15); do sleep 0.1; done
        echo done > "$out/finished"
        """)
        let run = Background(cancellation) {
            try cancellation.deferring("the CFW install") { try runBash(script, standIn.directory) }
        }
        _ = try #require(standIn.pid("child.pid"))
        cancellation.request(signal: SIGINT)
        let result = try #require(run.wait(), "the deferred stage did not return")
        let finished = Date()
        #expect(try result.get() == 0)
        #expect(standIn.exists("finished"))
        #expect(!standIn.exists("got-int"))
        #expect(cancellation.isRequested)
        #expect(recorder.logged.contains { $0.contains("cannot be stopped from this process") })
        // While deferred no exit was taken; once the deferral ends and the
        // operation does not return, the process exits with 128 + SIGINT.
        let exitDeadline = Date().addingTimeInterval(5)
        while recorder.exitCodes.isEmpty, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(recorder.exitCodes.first == 130)
        #expect((recorder.exitTimes.first ?? .distantPast) >= finished)
    }

    @Test func forcedExitWaitsForACheckpointWriteInProgress() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder, forcedExit: 0.2)
        defer { cancellation.complete() }
        let holder = Background(cancellation) {
            cancellation.withExitDeferred { Thread.sleep(forTimeInterval: 0.8); return Date() }
        }
        Thread.sleep(forTimeInterval: 0.05)
        cancellation.request(signal: SIGTERM)
        let released = try #require(try holder.wait()?.get())
        let deadline = Date().addingTimeInterval(5)
        while recorder.exitCodes.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(recorder.exitCodes == [128 + SIGTERM])
        #expect((recorder.exitTimes.first ?? .distantPast) >= released)
    }

    @Test func completedOperationIsNotExitedLater() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder, forcedExit: 0.1)
        cancellation.request(signal: SIGINT)
        cancellation.complete()
        Thread.sleep(forTimeInterval: 0.4)
        #expect(recorder.exitCodes.isEmpty)
    }

    @Test func processTableListsThisProcessWithItsParentAndGroup() {
        let entry = VPhoneProcessInfo.table().first { $0.pid == getpid() }
        #expect(entry == .init(pid: getpid(), ppid: getppid(), pgid: getpgrp()))
    }
}

// MARK: - Runner

/// "<stage> <signal>" of an `interrupted` error, or a description of anything else.
private func interruption<T>(_ result: Result<T, Error>) -> String {
    switch result {
    case .success: return "no error"
    case let .failure(VPhoneCreateRunError.interrupted(stage, signal)):
        return "\(stage.rawValue) \(VPhoneChildCancellation.name(of: signal))"
    case let .failure(error): return "\(error)"
    }
}

private struct NoFailure: Error {}

/// Prepare runs a stand-in child; every other stage writes nothing. The cfw
/// stage runs its child inside `deferring`, like the real root CFW install.
private final class ChildStages: VPhoneCreateStageExecutor, VPhoneCreateStageVerifier, VPhoneCreateStateProber,
    @unchecked Sendable
{
    let version = "child-stages-1"
    let scripts: [VPhoneCreateStage: URL]
    let argument: URL
    private let lock = NSLock()
    private var ran: [VPhoneCreateStage] = []
    var executed: [VPhoneCreateStage] { lock.withLock { ran } }

    init(scripts: [VPhoneCreateStage: URL], argument: URL) {
        self.scripts = scripts
        self.argument = argument
    }

    func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String] {
        lock.withLock { ran.append(stage) }
        guard let script = scripts[stage] else { return ["ran": stage.rawValue] }
        let code = try stage == .cfw
            ? VPhoneChildCancellation.deferring("the CFW install") { try runBash(script, argument) }
            : runBash(script, argument)
        guard code == 0 else { throw NSError(domain: "stand-in", code: Int(code)) }
        return ["ran": stage.rawValue]
    }

    func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String> { [] }
    func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool { false }

    func verify(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]) -> VPhoneCreateVerification {
        evidence["ran"] == stage.rawValue ? .verified(artifacts: [], evidence: [:]) : .rejected("no evidence")
    }

    func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult {
        .idle(evidence: "stand-in")
    }
}

@Suite struct CreateRunnerCancellationTests {
    static func options() -> VPhoneCreateEffectiveOptions {
        .init(variant: "regular", iphoneSource: "/ipsw/iPhone.ipsw", cloudosSource: "/ipsw/cloudOS.ipsw", spoofBuild: nil,
              forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
    }

    fileprivate static func runner(_ stages: ChildStages, _ cancellation: VPhoneChildCancellation) -> VPhoneCreateRunner {
        VPhoneCreateRunner(
            executor: stages, verifier: stages, prober: stages,
            storeHooks: .init(acquireBundleLock: { try VPhoneVMLock(directory: $0, operation: VPhoneVMOperation.createCheckpoint) }),
            toolFingerprint: { "tool" }, log: { _ in }, cancellation: cancellation)
    }

    @Test func signalDuringAStageLeavesItRunningEndsItsChildrenAndReleasesTheLocks() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder)
        let standIn = try StandIn()
        var identities: [VPhoneProcessIdentity] = []
        defer { cancellation.complete(); standIn.cleanup(identities) }
        let bundle = standIn.directory.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let stages = ChildStages(scripts: [.prepare: try standIn.script("prepare.sh", treeScript)], argument: standIn.directory)
        let run = Background(cancellation) {
            try Self.runner(stages, cancellation).create(
                bundleURL: bundle, options: Self.options(), iphoneSource: "/ipsw/iPhone.ipsw", cloudosSource: "/ipsw/cloudOS.ipsw")
        }
        for name in ["child.pid", "ignoring.pid", "grouped.pid"] {
            identities.append(try #require(standIn.pid(name).flatMap(VPhoneProcessInfo.identity(of:))))
        }
        cancellation.request(signal: SIGINT)
        let result = try #require(run.wait(), "create did not return")
        #expect(interruption(result) == "prepare SIGINT")
        // Every stage process ended before the runner returned.
        for identity in identities { #expect(!alive(identity), "pid \(identity.pid) survived the runner") }
        let checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: bundle).checkpoint
        #expect(checkpoint.record(.prepare).status == .running)
        #expect(checkpoint.record(.prepare).error?.contains("interrupted by SIGINT") == true)
        #expect(checkpoint.record(.prepare).error?.contains("every stage process ended") == true)
        #expect(checkpoint.record(.patch).status == .pending)
        #expect(checkpoint.overallStatus == .interrupted)
        #expect(stages.executed == [.prepare])
        #expect(!VPhoneCreateCheckpointStore.isRunLockHeld(bundleURL: bundle))
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: bundle))
        #expect(recorder.exitCodes.isEmpty)

        // Resume reprobes and reruns the interrupted stage.
        let resumed = try Self.runner(ChildStages(scripts: [:], argument: standIn.directory), controller(Recorder()))
            .resume(bundleURL: bundle)
        #expect(resumed.record(.prepare).status == .succeeded)
        #expect(resumed.record(.prepare).history.last?.error?.contains("interrupted by SIGINT") == true)
        #expect(resumed.overallStatus == .succeeded)
    }

    @Test func signalBeforeAStageStopsWithoutRunningIt() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder)
        let standIn = try StandIn()
        defer { cancellation.complete(); standIn.cleanup([]) }
        let bundle = standIn.directory.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let stages = ChildStages(scripts: [:], argument: standIn.directory)
        cancellation.request(signal: SIGTERM)
        let result = Result {
            try Self.runner(stages, cancellation).create(
                bundleURL: bundle, options: Self.options(), iphoneSource: nil, cloudosSource: nil)
        }
        #expect(interruption(result) == "prepare SIGTERM")
        #expect(stages.executed.isEmpty)
        let checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: bundle).checkpoint
        #expect(checkpoint.record(.prepare).status == .running)
        #expect(checkpoint.overallStatus == .interrupted)
    }

    /// CFW (root) is waited for: its child gets no signal, the stage is
    /// recorded as it finished, and the next stage is the interrupted one.
    @Test func signalDuringTheDeferredCFWStageStopsAfterIt() throws {
        let recorder = Recorder()
        let cancellation = controller(recorder)
        let standIn = try StandIn()
        defer { cancellation.complete(); standIn.cleanup([]) }
        let bundle = standIn.directory.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let cfw = try standIn.script("cfw.sh", """
        trap 'echo int > "$out/got-int"' INT
        echo $$ > "$out/child.pid"
        for i in $(seq 1 10); do sleep 0.1; done
        """)
        let stages = ChildStages(scripts: [.cfw: cfw], argument: standIn.directory)
        let run = Background(cancellation) {
            try Self.runner(stages, cancellation).create(
                bundleURL: bundle, options: Self.options(), iphoneSource: nil, cloudosSource: nil)
        }
        _ = try #require(standIn.pid("child.pid"))
        cancellation.request(signal: SIGINT)
        let result = try #require(run.wait())
        #expect(interruption(result) == "first_boot SIGINT")
        #expect(!standIn.exists("got-int"))
        let checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: bundle).checkpoint
        #expect(checkpoint.record(.cfw).status == .succeeded)
        #expect(checkpoint.record(.firstBoot).status == .running)
        #expect(checkpoint.overallStatus == .interrupted)
        #expect(stages.executed == [.prepare, .patch, .restore, .cfw])
    }
}
