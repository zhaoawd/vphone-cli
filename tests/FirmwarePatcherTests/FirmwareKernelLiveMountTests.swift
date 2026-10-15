import Darwin
import Foundation
import Img4tool
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareKernelLiveMountTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_MOUNT_INTEGRATION_IMAGE"] != nil))
    func liveCandidateSwapAndReadonlyReadback() throws {
        let env = ProcessInfo.processInfo.environment
        #expect(geteuid() == 0)
        let fixture = try FirmwareComponentReceiptTests.Fixture()
        let transaction = try FirmwareReceiptPublicationTests().begin(fixture)
        let candidate = transaction.work.appendingPathComponent("kernel-candidate.img")
        let source = try #require(env["VPHONE_MOUNT_INTEGRATION_IMAGE"])
        guard clonefile(source, candidate.path, 0) == 0 else { throw POSIXError(.EIO) }
        print("LIVE mount transaction", transaction.vmDirectory.path, "candidate", candidate.path)
        let evidence = URL(fileURLWithPath: try #require(env["VPHONE_MOUNT_EVIDENCE"]))
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        func operations(writable: Bool) -> FirmwareInstalledReadback.Operations {
            let live = FirmwareInstalledReadback.liveOperations(transaction: transaction, writablePreboot: writable)
            var count = 0
            return .init(attach: live.attach, inspect: { attachment in
                count += 1
                let observation = try live.inspect(attachment)
                let label = (writable ? "rw" : "ro") + "-\(count)"
                try observation.images.write(to: evidence.appendingPathComponent(label + "-images.plist"))
                try observation.containers.write(to: evidence.appendingPathComponent(label + "-containers.plist"))
                var roots: [String: Any] = [:]
                for (name, volume) in attachment.volumes {
                    try observation.volumes[name]?.write(to: evidence.appendingPathComponent(label + "-" + name + ".plist"))
                    var fs = statfs()
                    guard statfs(volume.root.path, &fs) == 0 else { throw POSIXError(.EIO) }
                    roots[name] = ["device": volume.device, "path": volume.root.path, "flags": fs.f_flags]
                }
                try JSONSerialization.data(withJSONObject: ["image": attachment.image.path, "device": attachment.device, "volumes": roots], options: [.prettyPrinted, .sortedKeys])
                    .write(to: evidence.appendingPathComponent(label + "-attachment.json"))
                return observation
            }, detach: live.detach)
        }
        var installed: Data?
        try transaction.withWorkerLock {
            try FirmwareKernelMount.withVolumes(image: candidate, transaction: transaction, writable: true, operations: operations(writable: true)) { roots in
                let preboot = try #require(roots["preboot"]), system = try #require(roots["system"])
                let target = try FirmwareKernelMount.uniqueKernel(in: preboot)
                let original = try Data(contentsOf: target)
                // Use the real prepared EXP producer and its declaration gate.
                let input = try Data(contentsOf: URL(fileURLWithPath: try #require(env["VPHONE_DSC_KERNEL_INPUT"])))
                let plan = try JSONDecoder().decode(FirmwareDesiredPlanStore.Record.self,
                    from: Data(contentsOf: URL(fileURLWithPath: try #require(env["VPHONE_DSC_EXP_PLAN"])))).plan
                let pipeline = FirmwarePipeline(vmDirectory: fixture.vm, variant: try #require(.init(rawValue: plan.variant)), verbose: false)
                let (payload, reports) = try pipeline.reproduceInstalledComponentReport("kernelcache", input: input, plan: plan)
                try PatchDeclarationGate.enforceKernel(report: .init(variant: plan.variant, gates: plan.gates, components: reports, ablation: []), plan: plan)
                let region = try FirmwareKernelRegion.inspect(payload)
                try FirmwareKernelDSC.validate(system: system, region: region)
                let im4p = try IM4P(fourcc: "krnl", description: "kernelcache", payload: payload).data
                let changed = try VPhoneKernelcacheSwap.replacingPayload(in: original, with: im4p)
                let replacement = try #require(changed)
                let handle = try FileHandle(forWritingTo: target)
                try handle.write(contentsOf: replacement); try handle.truncate(atOffset: UInt64(replacement.count)); try handle.synchronize(); try handle.close()
                #expect(try Data(contentsOf: target) == replacement)
                installed = replacement
                print("LIVE writable candidate kernel replacement and DSC validation passed")
            }
            try FirmwareKernelMount.withVolumes(image: candidate, transaction: transaction, writable: false, operations: operations(writable: false)) { roots in
                let target = try FirmwareKernelMount.uniqueKernel(in: #require(roots["preboot"]))
                #expect(try Data(contentsOf: target) == installed)
                try FirmwareKernelDSC.validate(system: #require(roots["system"]), region: .init(base: 0x180000000, size: 6 << 30))
                print("LIVE readonly candidate kernel readback and DSC validation passed")
            }
        }
    }
}
