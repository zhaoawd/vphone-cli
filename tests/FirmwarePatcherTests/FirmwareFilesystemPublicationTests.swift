import Foundation
import CryptoKit
import Testing
@testable import FirmwarePatcher

private final class FilesystemPublicationTestBundle: NSObject {}

@Suite struct FirmwareFilesystemPublicationTests {
    @Test(arguments: ["success", "lost-effect", "detach"])
    func finalFilesystemIsReverifiedAfterPublication(_ fault: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture(variant: .less)
        guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: f.vm) else { throw POSIXError(.EINVAL) }
        let restore = try #require(f.generation.content.originals.first { $0.name.contains("Restore") }?.name)
        let mount = f.vm.appendingPathComponent(".firmware-transaction/work/final-mount")
        let target = mount.appendingPathComponent("usr/libexec/mobileactivationd")
        var environment: [String: String] = [:]
        var publicationReads = 0
        let t = try FirmwareTransaction(vmDirectory: f.vm,
            inputs: f.generation.content.originals.map { f.vm.appendingPathComponent($0.name) },
            options: ["variant": "less", "generationID": f.generation.id, "desiredSHA256": try desired.sha256,
                      "noBinpack": "true", "noVphoned": "true"],
            plan: f.plan, versionInputs: FirmwareVersionInputs.read(in: f.vm), inject: { event in
                if fault == "lost-effect", event == .afterPublish(restore) { try Data([0]).write(to: target) }
            }, mounts: { _, _ in }, filesystemReadback: { evidence, image, transaction, _ in
                let published = image.path.hasPrefix(transaction.vmDirectory.path + "/" + restore)
                if published { publicationReads += 1 }
                let operations = FirmwareFilesystemReadback.Operations(decrypt: { image in
                    let output = transaction.work.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: image, to: output); return output
                }, attach: { .init(image: $0, device: "owned-synthetic-device", mount: mount, readOnly: true) }, detach: { _ in
                    if published && fault == "detach" { throw POSIXError(.EBUSY) }
                })
                try evidence.verify(image: image, transaction: transaction, environment: environment, operations: operations)
            })
        environment = try FirmwareGuestWriteContext.environment(record: desired, directory: f.vm, transaction: t.root)
        // Use the real scratch CLI verifier, not the XCTest executable.
        var search = Bundle(for: FilesystemPublicationTestBundle.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.isExecutableFile(atPath: search.appendingPathComponent("vphone-cli").path) { break }
            search.deleteLastPathComponent()
        }
        let verifier = search.appendingPathComponent("vphone-cli")
        var context = try #require(JSONSerialization.jsonObject(with: Data(environment["VPHONE_FROZEN_CONTEXT"]!.utf8)) as? [String: Any])
        context["verifierPath"] = verifier.path
        context["verifierSHA256"] = try FirmwareGeneration.fileSHA256(verifier)
        environment["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let producer = #"""
        import sys,os
        from pathlib import Path
        sys.path.insert(0,sys.argv[1])
        from patchers import component_effects as effects,plan_gate as gate
        import verify_component_effects
        plan=gate.from_environment();transaction=Path(plan.context['filesystemTransaction'])
        mount=transaction/'work/final-mount';target=mount/'usr/libexec/mobileactivationd'
        target.parent.mkdir(parents=True);target.write_bytes(b'\x00')
        store=transaction/'effect-blobs';before=gate.snapshot(target);preserved=effects.capture_input(target,store)
        target.write_bytes(b'\x01')
        gate.append_evidence(plan,'filesystem-less-cryptex_merge','system:/usr/libexec/mobileactivationd',target,
            before,gate.snapshot(target),effect=effects.capture_change(preserved,target,store))
        verify_component_effects.run('capture',mount,transaction/'filesystem-tree-proof.json')
        """#
        _ = try t.runTool("/usr/bin/env", environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
            + [repo.appendingPathComponent(".venv/bin/python3").path, "-c", producer, repo.appendingPathComponent("scripts").path])
        let image = t.stage.appendingPathComponent(restore + "/final.aea")
        let imageBytes = Data("encrypted filesystem stand-in".utf8); try imageBytes.write(to: image)
        let evidence = try FirmwareFilesystemEvidence.capture(image: image, transaction: t); try evidence.persist(in: t)
        func manifest(path: String, digest: Data) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["BuildIdentities": [["Manifest": ["OS": [
                "Info": ["Path": path], "Digest": digest]]]]], format: .xml, options: 0)
        }
        let before = try manifest(path: "old.aea", digest: Data([0]))
        let intermediate = try manifest(path: "final.aea", digest: Data([0]))
        let final = try manifest(path: "final.aea", digest: Data(SHA384.hash(data: imageBytes)))
        let manifestURL = t.stage.appendingPathComponent(restore + "/BuildManifest.plist"); try final.write(to: manifestURL)
        let base = RequiredDeclarationEvidenceTests.complete(f.plan)
        let reports = base.components.map { component -> ComponentReport in
            guard component.component == "filesystem" || component.component == "manifest" else { return component }
            let old = component.records[0]
            let record = PatchRecord(patchID: old.patchID, component: old.component, fileOffset: 0,
                originalBytes: component.component == "filesystem" ? before : intermediate,
                patchedBytes: component.component == "filesystem" ? intermediate : final, description: "actual manifest mutation")
            return ComponentReport(component: component.component, coverage: component.coverage, results: component.results, records: [record])
        }
        let report = PatchRunReport(variant: base.variant, gates: base.gates, components: reports, ablation: [])
        var outputs: [String: URL] = ["filesystem": manifestURL, "manifest": manifestURL]
        for component in Set(report.allRecords.map(\.component)).subtracting(["filesystem", "manifest"]) {
            let url = t.stage.appendingPathComponent(component == "avpbooter" ? f.file.lastPathComponent : restore + "/" + component + ".bin")
            try Data([1]).write(to: url); outputs[component] = url
        }
        try t.saveReport(report)
        try t.prepareComponentReceipts(report: report, outputs: outputs)
        if fault == "success" {
            _ = try t.commit()
            #expect(publicationReads >= 2)
            #expect(t.journalSnapshot.phase == .committed)
        } else {
            #expect(throws: (any Error).self) { try t.commit() }
            #expect(t.journalSnapshot.phase != .committed)
            #expect(publicationReads == 1)
            _ = try FirmwareTransaction.recover(vmDirectory: f.vm, mounts: { _, _ in })
            #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(restore + "/final.aea").path))
        }
    }
}
