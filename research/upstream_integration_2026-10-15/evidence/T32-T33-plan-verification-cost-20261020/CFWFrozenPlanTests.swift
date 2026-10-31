import ArgumentParser
import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import Virtualization
import VPhoneCore
@testable import vphone_cli

private final class CFWFrozenTestBundle: NSObject {}

@Suite struct CFWFrozenPlanTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_PLAN_COST_FIXTURE"] != nil))
    func prepareIsolatedPlanCostFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VPHONE_PLAN_COST_FIXTURE"]))
        try #require(!FileManager.default.fileExists(atPath: path.path), "benchmark fixture must be new")
        let vm = try fixture(profile: false, variant: .exp, directory: path)
        let disk = try FileHandle(forWritingTo: vm.appendingPathComponent("Disk.img"))
        try disk.truncate(atOffset: 64 << 20)
        try disk.close()
        let context = try VPhoneCFWFrozenContext.prepare(in: vm, requestedVariant: nil, guestEnvironment: "classic", spoofBuild: "")
        let verifier = try executable()
        var object = try #require(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        object["verifierPath"] = verifier.path
        object["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        var env = ProcessInfo.processInfo.environment.merging(try context.environment) { _, new in new }
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let python = root.appendingPathComponent(".venv/bin/python3")
        let result = try VPhoneProcessRunner.runCapturing(python, [root.appendingPathComponent("scripts/vm_lock.py").path,
            vm.path, "cfw-record", "--", python.path, root.appendingPathComponent("tests/cfw_identity_bridge_fixture.py").path, vm.path], env: env)
        try #require(result.succeeded, Comment(rawValue: result.stdout + result.stderr))
        guard case .ready = try FirmwareDesiredPlanStore.read(in: vm) else { Issue.record("benchmark plan invalid"); return }
        print("[plan-cost-fixture] retained isolated 64MiB fixture with two CFW publications and Undo at \(vm.path)")
    }
    @Test(arguments: ["valid", "checkpoint", "disk", "machine", "retained", "postimage", "postimage-replaced", "runtime-resized"])
    func committedCFWSwapPreservesActualSwiftGenerationQualification(change: String) throws {
        let vm = try fixture(profile: false, variant: .exp)
        defer { try? FileManager.default.removeItem(at: vm) }
        let context = try VPhoneCFWFrozenContext.prepare(in: vm, requestedVariant: nil, guestEnvironment: "classic", spoofBuild: "")
        let original = try VPhoneFirmwareIdentity.read(in: vm)
        let verifier = try executable()
        var object = try #require(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        object["verifierPath"] = verifier.path
        object["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        var env = ProcessInfo.processInfo.environment.merging(try context.environment) { _, new in new }
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys,.withoutEscapingSlashes]), as: UTF8.self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".venv/bin/python3")
        let result = try VPhoneProcessRunner.runCapturing(python,[root.appendingPathComponent("scripts/vm_lock.py").path,
            vm.path,"cfw-record","--",python.path,root.appendingPathComponent("tests/cfw_identity_bridge_fixture.py").path,vm.path],env:env)
        #expect(result.succeeded, Comment(rawValue: result.stdout + result.stderr))
        #expect(try VPhoneFirmwareIdentity.read(in: vm) != original)
        #expect(try FirmwareGeneration.loadVerified(in: vm,id:context.generationID).content.identity == original)
        #expect(try VPhoneCFWFrozenContext.prepare(in: vm,requestedVariant:nil,guestEnvironment:"classic",spoofBuild:"").generationID == context.generationID)
        if change == "valid" { return }
        let archive = try #require(FileManager.default.contentsOfDirectory(at: vm.appendingPathComponent(".cfw-history"),
            includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasSuffix("identity2") }))
        switch change {
        case "checkpoint":
            let file = archive.appendingPathComponent("guest-publication.json")
            var bytes = try Data(contentsOf: file); bytes.append(32); try bytes.write(to: file)
        case "disk":
            let file = vm.appendingPathComponent("Disk.img"), data = try Data(contentsOf: file)
            try FileManager.default.moveItem(at: file, to: vm.appendingPathComponent("unrelated-old"))
            try data.write(to: file)
        case "postimage":
            let file = archive.appendingPathComponent("guest-postimage.img")
            let stream = try FileHandle(forWritingTo: file)
            try stream.write(contentsOf: Data([0x52])); try stream.close()
        case "postimage-replaced":
            let file = archive.appendingPathComponent("guest-postimage.img"), data = try Data(contentsOf: file)
            try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent("held-postimage"))
            try data.write(to: file)
        case "runtime-resized":
            let stream = try FileHandle(forWritingTo: vm.appendingPathComponent("Disk.img"))
            try stream.seekToEnd(); try stream.write(contentsOf: Data([0x52])); try stream.close()
        case "machine":
            let file = vm.appendingPathComponent("config.plist")
            var config = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file),format:nil) as? [String:Any])
            config["machineIdentifier"] = VZMacMachineIdentifier().dataRepresentation
            try PropertyListSerialization.data(fromPropertyList:config,format:.xml,options:0).write(to:file)
        case "retained": try Data("changed retained disk".utf8).write(to:archive.appendingPathComponent("Disk.img"))
        default: Issue.record("Unknown identity fixture")
        }
        #expect(throws: (any Error).self) { try FirmwareGeneration.loadVerified(in:vm,id:context.generationID) }
    }
    private func fixture(profile: Bool, variant: FirmwarePipeline.Variant = .regular, directory: URL? = nil) throws -> URL {
        let path = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("cfw-frozen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let vm = path.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        let restore = vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: vm.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try Data("synthetic disk".utf8).write(to: vm.appendingPathComponent("Disk.img"))
        try PropertyListSerialization.data(fromPropertyList: ["machineIdentifier": VZMacMachineIdentifier().dataRepresentation,
            "diskImage": "Disk.img"], format: .xml, options: 0).write(to: vm.appendingPathComponent("config.plist"))
        for name in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
            try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": "26.1", "ProductBuildVersion": "23B85"],
                format: .xml, options: 0).write(to: restore.appendingPathComponent(name))
        }
        try Data("generation SystemOS fixture".utf8).write(to: restore.appendingPathComponent("SystemOS.dmg"))
        let pipeline = FirmwarePipeline(vmDirectory: vm, variant: variant, verbose: false, guestEnvironmentV2: profile)
        let plan = try pipeline.resolvedPlan(), inputs = try pipeline.transactionRoots()
        let source = FirmwareGeneration.Source(provenance: .init(recognition: "fresh-local-ipsw-prepare-v1",
            inputManifestSHA256: [:], archiveSHA256: [:], builds: [:], device: "synthetic-test", gpuInputs: [],
            bootROMSHA256: String(repeating: "0", count: 64)), originals: try inputs.map {
                .init(name: $0.lastPathComponent, sha256: try FirmwareGeneration.treeDigest($0))
            }.sorted { $0.name < $1.name }, directory: vm)
        let generation = try FirmwareGeneration.publish(FirmwareGeneration.prepare(in: vm, inputs: inputs, source: source),
            planSHA256: FirmwareGeneration.planDigest(plan))
        _ = try FirmwareDesiredPlanStore.publish(FirmwareDesiredPlanStore.prepare(in: vm, plan: plan, generation: generation), expectedSHA256: nil)
        return vm
    }

    private func executable() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["VPHONE_TEST_CLI"],
           FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        var directory = Bundle(for: CFWFrozenTestBundle.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("vphone-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw ValidationError("scratch vphone-cli executable missing")
    }

    @Test(arguments: [(false, "regular"), (true, "regular"), (false, "dev"), (false, "jb"), (false, "exp")])
    func actualSwiftVerifierDrivesPythonAndZshWrites(settings: (Bool, String)) throws {
        let (profile, variantName) = settings
        let variant = try #require(FirmwarePipeline.Variant(rawValue: variantName))
        let vm = try fixture(profile: profile, variant: variant)
        defer { try? FileManager.default.removeItem(at: vm) }
        let context = try VPhoneCFWFrozenContext.prepare(in: vm, requestedVariant: nil,
            guestEnvironment: profile ? "v2" : "classic", spoofBuild: "")
        var object = try #require(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        let verifier = try executable()
        object["verifierPath"] = verifier.path
        object["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        var env = ProcessInfo.processInfo.environment.merging(try context.environment) { _, new in new }
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mount = vm.appendingPathComponent(".cfw_mount.fixture"), stage = vm.appendingPathComponent(".cfw_temp")
        let relative = profile ? "usr/lib/libcamfix.dylib" : "System/Library/LaunchDaemons/dropbear.plist"
        let target = mount.appendingPathComponent("mnt1/" + relative), source = stage.appendingPathComponent(profile ? "libcamfix.dylib" : "dropbear.plist")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target)
        try (profile ? Data("actual v2 library".utf8) : PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": ["dropbear"]], format: .xml, options: 0)).write(to: source)
        env["CFW_HOST_MNT"] = mount.path
        env["VPHONE_GUEST_EVIDENCE"] = vm.appendingPathComponent(".cfw_disk.fixture/guest-changes.jsonl").path
        env["TEST_SOURCE"] = source.path; env["TEST_TARGET"] = target.path
        env["VM_DIR"] = vm.path; env["CFW_INPUT"] = "cfw_input"
        env["TEST_VARIANT"] = variantName
        env["SCRIPT_DIR"] = root.appendingPathComponent("scripts").path
        env["PYTHON3"] = root.appendingPathComponent(".venv/bin/python3").path
        let body = #"""
        set -euo pipefail
        source "$SCRIPT_DIR/lib/cfw_common.sh"
        installer=cfw_install.sh
        [[ "$TEST_VARIANT" == regular ]] || installer="cfw_install_${TEST_VARIANT}.sh"
        "$PYTHON3" "$SCRIPT_DIR/patchers/plan_gate.py" entry "$installer"
        if [[ "$VPHONE_GUEST_ENVIRONMENT" == classic ]]; then
            "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-dropbear-plist "$TEST_SOURCE"
        fi
        "$PYTHON3" - <<'PYSIGN'
        import os, sys
        from pathlib import Path
        root=Path(os.environ['SCRIPT_DIR']).parent;sys.path.insert(0,str(root))
        from tests.test_component_signatures import signed_macho
        vm=Path(os.environ['VM_DIR']);unsigned=bytearray(signed_macho()[:4096])
        unsigned[16:24]=b'\0'*8;unsigned[32:48]=b'\0'*16
        (vm/'.cfw_temp/seputil').write_bytes(unsigned)
        (vm/'signed.fixture').write_bytes(signed_macho(entitlements={'fixture':True}))
        directory=vm/'fixture-bin';directory.mkdir()
        signer=directory/'ldid';signer.write_text('#!/bin/sh\nfor target; do :; done\n/bin/cat "$VM_DIR/signed.fixture" > "$target"\n');signer.chmod(0o755)
        (Path(os.environ['CFW_HOST_MNT'])/'mnt1/usr/libexec').mkdir(parents=True,exist_ok=True)
        PYSIGN
        export PATH="$VM_DIR/fixture-bin:$PATH"
        ldid_sign "$VM_DIR/.cfw_temp/seputil" com.apple.seputil
        cfw_guest_write /bin/cp "$VM_DIR/.cfw_temp/seputil" "$CFW_HOST_MNT/mnt1/usr/libexec/seputil"
        cfw_guest_write /bin/chmod 0755 "$CFW_HOST_MNT/mnt1/usr/libexec/seputil"
        cfw_guest_write /bin/cp "$TEST_SOURCE" "$TEST_TARGET"
        "$PYTHON3" - <<'PYVERIFY'
        import os, sys, json
        from pathlib import Path
        sys.path.insert(0, os.environ['SCRIPT_DIR'])
        from patchers import component_effects, plan_gate
        plan = plan_gate.from_environment()
        evidence = Path(os.environ['VPHONE_GUEST_EVIDENCE'])
        rows = [json.loads(line) for line in evidence.read_bytes().splitlines()]
        component_effects.verify_rows(plan, rows, {'system': Path(os.environ['CFW_HOST_MNT'])/'mnt1'}, evidence.parent/'effect-blobs')
        PYVERIFY
        """#
        let process = Process(); process.executableURL = root.appendingPathComponent(".venv/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/vm_lock.py").path, vm.path, "cfw-test", "--", "/bin/zsh", "-c", body]
        process.environment = env; let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: bytes, as: UTF8.self))")
        #expect(try Data(contentsOf: target) == Data(contentsOf: source))
        let lines = try String(contentsOfFile: #require(env["VPHONE_GUEST_EVIDENCE"]), encoding: .utf8).split(separator: "\n")
        let lastLine = try #require(lines.last)
        let last = try #require(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        #expect(last["planDigest"] as? String == context.planSHA256)
        #expect(last["beforeSHA256"] as? String == SHA256.hash(data: Data("old".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(last["afterSHA256"] as? String == SHA256.hash(data: try Data(contentsOf: target)).map { String(format: "%02x", $0) }.joined())
        #expect(throws: (any Error).self) { try VPhoneCFWFrozenContext.prepare(in: vm, requestedVariant: variantName == "exp" ? "dev" : "exp", guestEnvironment: profile ? "v2" : "classic", spoofBuild: "") }
        #expect(throws: (any Error).self) { try VPhoneCFWFrozenContext.prepare(in: vm, requestedVariant: nil, guestEnvironment: profile ? "classic" : "v2", spoofBuild: "") }
    }
    @Test func lessFilesystemSuboperationUsesSameVerifiedPlan() throws {
        let vm = try fixture(profile: false, variant: .less)
        defer { try? FileManager.default.removeItem(at: vm) }
        guard case .ready(let record) = try FirmwareDesiredPlanStore.read(in: vm) else { throw FirmwareDesiredPlanStore.Failure.missing }
        let inputs = try FirmwarePipeline(vmDirectory: vm, variant: .less, verbose: false).transactionRoots()
        let transaction = try FirmwareTransaction(vmDirectory: vm, inputs: inputs,
            options: ["variant": "less", "desiredSHA256": try record.sha256, "generationID": record.generationID], plan: record.plan,
            versionInputs: try FirmwareVersionInputs.read(in: vm.appendingPathComponent("iPhone17,3_26.1_23B85_Restore")))
        var env = ProcessInfo.processInfo.environment.merging(try FirmwareGuestWriteContext.environment(record: record, directory: vm, transaction: transaction.root)) { _, new in new }
        let contextJSON = try #require(env["VPHONE_FROZEN_CONTEXT"])
        var context = try #require(JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [String: Any])
        let verifier = try executable()
        context["verifierPath"] = verifier.path
        context["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = try transaction.temporaryDirectory(), target = directory.appendingPathComponent("launchd.plist"), jobs = directory.appendingPathComponent("jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: false)
        try PropertyListSerialization.data(fromPropertyList: ["LaunchDaemons": ["existing": ["Label": "existing"]]], format: .xml, options: 0).write(to: target)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.vphone.vphoned"], format: .xml, options: 0).write(to: jobs.appendingPathComponent("vphoned.plist"))
        let python = root.appendingPathComponent(".venv/bin/python3")
        func execute(_ path: URL, extraContext: [String: Any]? = nil) throws -> Int32 {
            let process = Process(); process.executableURL = python
            process.arguments = [root.appendingPathComponent("scripts/firmware_worker.py").path, transaction.root.path, python.path,
                root.appendingPathComponent("scripts/patchers/cfw.py").path, "inject-daemons", path.path, jobs.path]
            var environment = env
            if let extraContext { environment["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: extraContext, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
            process.environment = environment; let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); _ = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return process.terminationStatus
        }
        let before = try Data(contentsOf: target)
        #expect(try execute(target) == 0)
        #expect(try Data(contentsOf: target) != before)
        let evidence = try Data(contentsOf: transaction.root.appendingPathComponent("guest-changes.jsonl"))
        let line = try #require(String(decoding: evidence, as: UTF8.self).split(separator: "\n").last)
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(row["declarationID"] as? String == "filesystem-less-cryptex_merge")
        #expect(row["planDigest"] as? String == record.planSHA256)
        let outside = vm.appendingPathComponent("launchd.plist"); try before.write(to: outside)
        #expect(try execute(outside) != 0)
        #expect(try Data(contentsOf: outside) == before)
        var wrong = context; wrong["variant"] = "exp"
        #expect(try execute(target, extraContext: wrong) != 0)
        wrong = context; wrong["filesystemTransaction"] = vm.appendingPathComponent("other").path
        #expect(try execute(target, extraContext: wrong) != 0)
    }

}
