import Foundation
import Testing
import Virtualization
import VPhoneCore
@testable import FirmwarePatcher
@testable import vphone_cli

@MainActor
final class GuestEnvironmentSourceFixture {
    let root: URL
    let machine: URL
    let executable: URL
    let stage: URL
    let runtime: VPhoneVMLock
    let version = "2.6.0-local.1234abcd"

    init() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("online-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("vm"), withIntermediateDirectories: true)
        root = path.standardizedFileURL.resolvingSymlinksInPath()
        machine = root.appendingPathComponent("vm").standardizedFileURL.resolvingSymlinksInPath()
        executable = root.appendingPathComponent("VPhone.bundle/Contents/MacOS/vphone-vm")
        stage = root.appendingPathComponent("VPhone.bundle/Contents/Resources/.build/guest-components-v2/stage")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let restore = machine.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: machine.appendingPathComponent("Disk.img"))
        try Data(repeating: 0, count: 64).write(to: machine.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
            "diskImage": "Disk.img"], format: .xml, options: 0).write(to: machine.appendingPathComponent("config.plist"))
        for name in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
            try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": "26.1", "ProductBuildVersion": "23B85"],
                format: .xml, options: 0).write(to: restore.appendingPathComponent(name))
        }
        let pipeline = FirmwarePipeline(vmDirectory: machine, variant: .regular, verbose: false, guestEnvironmentV2: true)
        let plan = try pipeline.resolvedPlan(), inputs = try pipeline.transactionRoots()
        let source = FirmwareGeneration.Source(provenance: .init(recognition: "fresh-local-ipsw-prepare-v1",
            inputManifestSHA256: [:], archiveSHA256: [:], builds: [:], device: "synthetic-online", gpuInputs: [],
            bootROMSHA256: String(repeating: "0", count: 64)), originals: try inputs.map {
                .init(name: $0.lastPathComponent, sha256: try FirmwareGeneration.treeDigest($0))
            }.sorted { $0.name < $1.name }, directory: machine)
        let generation = try FirmwareGeneration.publish(FirmwareGeneration.prepare(in: machine, inputs: inputs, source: source),
            planSHA256: FirmwareGeneration.planDigest(plan))
        _ = try FirmwareDesiredPlanStore.publish(FirmwareDesiredPlanStore.prepare(in: machine, plan: plan, generation: generation), expectedSHA256: nil)
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: version)).write(to: machine.appendingPathComponent("launchpad.json"))
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("vm executable".utf8).write(to: executable)
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: VPhoneGuestEnvironmentTestSupport.manifestURL,
                                        to: resources.appendingPathComponent("scripts/guest_environment.json"))
        _ = try VPhoneGuestEnvironmentTestSupport.stage(at: stage)
        let daemon = resources.appendingPathComponent(".build/daemon-api-v2/candidate-v2/vphoned")
        try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("daemon".utf8).write(to: daemon)
        runtime = try VPhoneVMLock(directory: machine, operation: VPhoneVMOperation.boot)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func withSource<T>(_ body: @MainActor (VPhoneGuestEnvironmentSource.Scope) async throws -> T) async throws -> T {
        try await VPhoneGuestEnvironmentSource.withVerifiedInput(runtime: runtime, version: version,
            executable: executable, effectiveExecutable: executable, requestedStage: stage.path,
            verifyBundle: {}, body: body)
    }
}

@Suite @MainActor struct GuestEnvironmentSourceTests {
    @Test func linkedCandidateParentCannotQualifyCurrentBundle() async throws {
        let fixture = try GuestEnvironmentSourceFixture()
        let original = fixture.stage.appendingPathComponent("camfix")
        let outside = fixture.root.appendingPathComponent("outside-candidates")
        try FileManager.default.moveItem(at: original, to: outside)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        do {
            try await fixture.withSource { _ in Issue.record("linked candidate parent qualified") }
        } catch {}
    }

    @Test func liveSourceRequiresActualRuntimePlanAndFilesAndExpires() async throws {
        let fixture = try GuestEnvironmentSourceFixture()
        var escaped: VPhoneGuestEnvironmentSource.Scope?
        try await fixture.withSource { source in
            escaped = source
            #expect(source.context["mode"] == "regular-v2")
            try source.verify()
            await Task.yield()
            try source.verify()
        }
        #expect(throws: Error.self) { try escaped?.verify() }
    }

    @Test func liveSourceRejectsMutationAndOutsideStage() async throws {
        let fixture = try GuestEnvironmentSourceFixture()
        do {
            try await fixture.withSource { _ in
                try Data("changed".utf8).write(to: fixture.stage.appendingPathComponent("camfix/libcamfix.dylib"))
            }
            Issue.record("changed candidate accepted")
        } catch {}
        do {
            try await VPhoneGuestEnvironmentSource.withVerifiedInput(runtime: fixture.runtime, version: fixture.version,
                executable: fixture.executable, effectiveExecutable: fixture.executable, requestedStage: "/tmp/untrusted",
                verifyBundle: {}) { _ in Issue.record("untrusted stage accepted") }
        } catch {}
    }

    @Test func sourceCannotSurviveFrozenPlanOrDaemonMutation() async throws {
        for path in [FirmwareDesiredPlanStore.filename, "daemon"] {
            let fixture = try GuestEnvironmentSourceFixture()
            do {
                try await fixture.withSource { _ in
                    let target = path == "daemon"
                        ? fixture.executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/.build/daemon-api-v2/candidate-v2/vphoned")
                        : fixture.machine.appendingPathComponent(path)
                    try Data("changed".utf8).write(to: target)
                }
                Issue.record("source or plan changed without refusal")
            } catch {}
        }
    }
}
