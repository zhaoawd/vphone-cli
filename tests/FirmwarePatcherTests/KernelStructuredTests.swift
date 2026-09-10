@testable import FirmwarePatcher
import Foundation
import Testing

struct KernelStructuredTests {
    @Test(arguments: [FirmwarePipeline.Variant.regular, .dev, .jb, .exp], [false, true])
    func excGuardMissingAnchorUsesExecutionGate(variant: FirmwarePipeline.Variant, force: Bool) throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            variant: variant, verbose: false, forceExcGuard: force)
        let descriptor = try #require(pipeline.buildComponentList().first { $0.name == "kernelcache" })
        let data = Data(repeating: 0, count: 0x1000)
        let patcher = try #require(descriptor.patcherFactories[0](data, false) as? KernelPatcher)
        let steps = patcher.buildSteps()
        let excGuard = try #require(steps.first { $0.id.method == "patchExcGuardBehavior" })
        let ablate = Set(steps.filter { $0.id != excGuard.id }.map { $0.id.description })
        let gates = pipeline.gateSnapshot
        let active = variant == .dev || force
        #expect(gates.excGuardActive == active)
        #expect(gates.excGuardActive == (patcher.isDev || patcher.applyExcGuard))
        let (report, output) = StructuredExecution.run(
            patcher: patcher, componentName: "kernelcache", gates: gates,
            ablate: ablate, fallback: data)
        let result = try #require(report.results.first { $0.id == excGuard.id })
        #expect(result.outcome == (active ? .failed : .notApplicable))
        #expect(report.hasRequiredFailure == active)
        #expect(report.records.isEmpty)
        #expect(output == data)
    }

    @Test func excGuardManifestRuleMatchesSteps() throws {
        let url = C1AlignmentTests.repoRoot().appendingPathComponent("research/firmware_compatibility.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let configurations = try #require(json["patch_configurations"] as? [[String: Any]])
        for cfg in configurations {
            let components = try #require(cfg["components"] as? [[String: Any]])
            for component in components {
                let methods = try #require(component["methods"] as? [[String: Any]])
                for method in methods where method["name"] as? String == "patchExcGuardBehavior" {
                    #expect(method["gate"] as? String == PatchRule.excGuardActive.rawValue)
                    if cfg["variant"] as? String == "dev" {
                        #expect((method["expected_not_applicable"] as? [String])?.isEmpty == true)
                    }
                }
            }
        }
    }
}

struct KernelJBStructuredTests {
    static let ios27Methods: Set<String> = [
        "patchIoucFailedSandbox", "patchDiskImages2ClientAbi", "patchExecSecurityPolicyKill",
        "patchContainerManagerUpcall", "patchIomfbSwapEndVariableSize", "patchIomfbSwapEndHandlerSize",
        "patchFpfsScopedVnodeOpen",
    ]
    static let fridaMethods: Set<String> = ["patchThreadSetStateEntitlementFlag", "patchVmMapDeleteImmutableCode"]
    static let optionalMethods: Set<String> = ["patchCredLabelUpdateExecve", "patchVmMapProtect"]

    static func gates(ios27: Bool = false, frida: Bool = false) -> PatchGateSnapshot {
        StructuredPatchResultTests.gates(iosBaseIs27: ios27, applyFrida: frida)
    }

    @Test func declarationsMatchOrchestratorAndManifest() throws {
        let patcher = KernelJBPatcher(data: Data(), verbose: false)
        let steps = patcher.buildSteps()
        let root = C1AlignmentTests.repoRoot()
        let source = try String(contentsOf: root.appendingPathComponent(
            "sources/FirmwarePatcher/Kernel/KernelJBPatcher.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s+(patch\w+)\(\)"#)
        let names = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
        #expect(steps.map(\.id.method) == names)
        #expect(steps.count == 33)
        #expect(Set(names).count == 33)
        #expect(patcher.segments.isEmpty)
        #expect(patcher.emittedRecords.isEmpty)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("research/firmware_compatibility.json"))) as? [String: Any])
        for cfg in try #require(json["patch_configurations"] as? [[String: Any]])
            where ["jb", "exp"].contains(cfg["variant"] as? String ?? "") {
            let components = try #require(cfg["components"] as? [[String: Any]])
            let kernel = try #require(components.first { $0["component"] as? String == "kernelcache" })
            let methods = try #require(kernel["methods"] as? [[String: Any]])
            for step in steps {
                let method = try #require(methods.first { $0["name"] as? String == step.id.method })
                #expect(method["required"] as? Bool == (step.requirement == .required))
                #expect(method["gate"] as? String == step.requirement.rule?.rawValue)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func missingAnchorsRespectGates(ios27: Bool, frida: Bool) throws {
        let data = Data(repeating: 0, count: 0x1000)
        let patcher = KernelJBPatcher(data: data, verbose: false)
        patcher.applyIOS27 = ios27
        patcher.applyFrida = frida
        let (report, output) = StructuredExecution.run(
            patcher: patcher, componentName: "kernelcache", gates: Self.gates(ios27: ios27, frida: frida),
            ablate: [], fallback: data)
        #expect(report.results.count == 33)
        for result in report.results {
            let method = result.id.method
            let inactive = (Self.ios27Methods.contains(method) && !ios27)
                || (Self.fridaMethods.contains(method) && !frida)
                || Self.optionalMethods.contains(method)
            #expect(result.outcome == (inactive ? .notApplicable : .failed), "\(method)")
            #expect(result.isRequiredFailure == !inactive, "\(method)")
        }
        #expect(report.records.isEmpty)
        #expect(output == data)
        let legacy = KernelJBPatcher(data: data, verbose: false)
        legacy.applyIOS27 = ios27
        legacy.applyFrida = frida
        #expect(try legacy.findAll() == report.records)
    }

    /// A minimal Mach-O with one executable range, for observing delayed setup.
    static func macho() -> Data {
        var data = Data(repeating: 0, count: 0x1000)
        func word(_ offset: Int, _ value: UInt32) {
            data.replaceSubrange(offset..<offset + 4, with: ARM64.encodeU32(value))
        }
        word(0, 0xFEED_FACF)
        word(4, 0x0100_000C)
        word(12, 2)
        word(16, 1)
        word(20, 72)
        word(32, 0x19)
        word(36, 72)
        data.replaceSubrange(40..<51, with: Data("__TEXT_EXEC".utf8) + Data([0]))
        word(64, 0x1000)
        word(72, 0x200)
        word(80, 0x100)
        return data
    }

    @Test func ablationPrecedesSetupAndLaterStepPreparesOnce() throws {
        let data = Self.macho()
        let all = KernelJBPatcher(data: data, verbose: false)
        let (report, output) = StructuredExecution.run(
            patcher: all, componentName: "kernelcache", gates: Self.gates(),
            ablate: ["kernelcache.KernelJBPatcher"], fallback: data)
        #expect(report.results.allSatisfy { $0.outcome == .ablated })
        #expect(all.segments.isEmpty)
        #expect(all.codeRanges.isEmpty)
        #expect(output == data)

        let later = KernelJBPatcher(data: data, verbose: false)
        let first = try #require(later.buildSteps().first)
        _ = StructuredExecution.run(
            patcher: later, componentName: "kernelcache", gates: Self.gates(),
            ablate: [first.id.description], fallback: data)
        #expect(later.codeRanges.count == 1)
        #expect(later.codeRanges.first?.start == 0x200)
        #expect(later.codeRanges.first?.end == 0x300)
        later.ensurePrepared()
        #expect(later.codeRanges.count == 1)
        #expect(later.emittedRecords.isEmpty)
    }

    @Test func iomfbAmbiguityReportsCountAndWritesNothing() throws {
        let patcher = KernelJBPatcher(data: Data(repeating: 0, count: 0x400), verbose: false)
        patcher.codeRanges = [(0x100, 0x180)]
        let cmp = try #require(ARM64Encoder.encodeCmpImmediateW(rn: 2, imm12: 0x588))
        for off in [0x100, 0x120] {
            patcher.buffer.writeBytes(at: off, bytes: cmp)
            patcher.buffer.writeBytes(at: off + 4, bytes: ARM64.encodeU32(0x5400_0041)) // b.ne +8
        }
        let input = patcher.buffer.data
        #expect(patcher.patchIomfbSwapEndHandlerSize() == .ambiguous(count: 2))
        #expect(patcher.emittedRecords.isEmpty)
        #expect(patcher.buffer.data == input)
    }
}

extension KernelJBStructuredTests {
    @Test func postValidationRecognizesIdempotenceWithoutEmitting() throws {
        let patcher = KernelJBPatcher(data: Data(repeating: 0, count: 0x1000), verbose: false)
        patcher.codeRanges = [(0x100, 0x244)]
        patcher.buffer.writeBytes(at: 0x800, bytes: Data("AMFI: code signature validation failed\0".utf8))
        patcher.buffer.writeBytes(at: 0x100, bytes: ARM64.pacibsp)
        patcher.buffer.writeBytes(at: 0x104, bytes: try #require(ARM64Encoder.encodeBL(from: 0x104, to: 0x200)))
        patcher.buffer.writeBytes(at: 0x108, bytes: try #require(ARM64Encoder.encodeADRP(rd: 0, pc: 0x108, target: 0x800)))
        patcher.buffer.writeBytes(at: 0x10C, bytes: ARM64.encodeU32(0x9100_0000 | (0x800 << 10))) // add x0,x0,#0x800
        patcher.buffer.writeBytes(at: 0x200, bytes: ARM64.pacibsp)
        patcher.buffer.writeBytes(at: 0x204, bytes: try #require(ARM64Encoder.encodeBL(from: 0x204, to: 0x300)))
        patcher.buffer.writeBytes(at: 0x208, bytes: try #require(ARM64Encoder.encodeCmpImmediateW(rn: 0, imm12: 1)))
        patcher.buffer.writeBytes(at: 0x20C, bytes: ARM64.encodeU32(0x5400_0041)) // b.ne +8
        patcher.buffer.writeBytes(at: 0x240, bytes: ARM64.pacibsp)
        let ready = KernelJBPatcher(data: patcher.buffer.data, verbose: false)
        ready.codeRanges = patcher.codeRanges
        ready.buildADRPIndex()
        #expect(ready.patchPostValidationAdditional() == .matched)
        #expect(ready.emittedRecords.count == 1)
        let output = ready.buffer.data
        #expect(ready.patchPostValidationAdditional() == .idempotent)
        #expect(ready.emittedRecords.count == 1)
        #expect(ready.buffer.data == output)
    }

    @Test(arguments: [false, true])
    func sandboxPartialFailurePreservesSuccessfulWrites(malformed: Bool) throws {
        let patcher = KernelJBPatcher(data: Data(repeating: 0, count: 0x2400), verbose: false)
        patcher.segments = [MachOSegmentInfo(name: "__DATA_CONST", vmAddr: 0,
            vmSize: 0x100, fileOffset: 0x100, fileSize: 0x100)]
        patcher.codeRanges = [(0x2000, 0x2040)]
        func pointer(_ offset: Int, _ value: UInt64) {
            var little = value.littleEndian
            patcher.buffer.writeBytes(at: offset, bytes: withUnsafeBytes(of: &little) { Data($0) })
        }
        patcher.buffer.writeBytes(at: 0x800, bytes: Data("Sandbox\0".utf8))
        patcher.buffer.writeBytes(at: 0x900, bytes: Data("Seatbelt sandbox policy\0".utf8))
        pointer(0x100, 0x800)
        pointer(0x108, 0x900)
        pointer(0x120, 0x300)
        pointer(0x300 + 201 * 8, (UInt64(1) << 63) | 0x2100)
        if malformed { pointer(0x300 + 202 * 8, 1) }
        patcher.buffer.writeBytes(at: 0x2000, bytes: ARM64.movX0_0 + ARM64.ret)
        let raw = patcher.patchSandboxHooksExtended()
        if malformed {
            #expect(raw == .encodeFail(reason: "incomplete extended sandbox hook retargeting"))
        } else {
            // NULL hooks have no implementation to retarget and retain legacy skip behavior.
            #expect(raw == .matched)
        }
        #expect(patcher.emittedRecords.count == 1)
        #expect(patcher.buffer.readU64(at: 0x300 + 201 * 8) == ((UInt64(1) << 63) | 0x2000))
        #expect(patcher.buffer.readU64(at: 0x300 + 202 * 8) == (malformed ? 1 : 0))
    }

    @Test func componentAblationIncludesBothKernelPatchers() throws {
        let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            variant: .jb, verbose: false)
        let components = pipeline.buildComponentList()
        let targets = pipeline.knownAblationTargets(components)
        #expect(targets.contains("kernelcache.KernelJBPatcher.patchThreadSetStateEntitlementFlag"))
        #expect(targets.contains("kernelcache.KernelJBPatcher.patchFpfsScopedVnodeOpen"))
        let kernel = try #require(components.first { $0.name == "kernelcache" })
        let input = Self.macho()
        let (output, reports) = try pipeline.patchDataStructured(input, componentName: "kernelcache",
            patcherFactories: kernel.patcherFactories, gates: pipeline.gateSnapshot, ablate: ["kernelcache"])
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.results.allSatisfy { $0.outcome == .ablated } })
        #expect(reports.allSatisfy { $0.records.isEmpty })
        #expect(output == input)
    }
}

extension KernelJBStructuredTests {
    @Test(arguments: [false, true])
    func diskImagesRequiresBothABIGatesButAllowsAbsentNotificationShape(connectPresent: Bool) throws {
        let patcher = KernelJBPatcher(data: Data(repeating: 0, count: 0x2000), verbose: false)
        patcher.codeRanges = [(0x100, 0x244)]
        let functions = [
            (0x100, 0x800, "static IOReturn DIDeviceCreatorUserClient::CreateDevice(OSObject *, void *, IOExternalMethodArguments *)"),
            (0x200, 0x1000, "static IOReturn DIDeviceIOUserClient::Connect(OSObject *, void *, IOExternalMethodArguments *)"),
        ]
        for (off, str, signature) in functions where off == 0x100 || connectPresent {
            patcher.buffer.writeBytes(at: str, bytes: Data((signature + "\0").utf8))
            patcher.buffer.writeBytes(at: off, bytes: ARM64.pacibsp)
            patcher.buffer.writeBytes(at: off + 4, bytes: try #require(
                ARM64Encoder.encodeADRP(rd: 0, pc: UInt64(off + 4), target: UInt64(str))))
            patcher.buffer.writeBytes(at: off + 8, bytes: ARM64.encodeU32(0x9100_0000 | UInt32(str & 0xFFF) << 10))
            patcher.buffer.writeBytes(at: off + 12, bytes: try #require(ARM64Encoder.encodeCmpImmediateW(rn: 0, imm12: 9)))
            patcher.buffer.writeBytes(at: off + 16, bytes: ARM64.encodeU32(0x5400_0041))
        }
        // Bound both recovered functions even when the second ABI signature is absent.
        patcher.buffer.writeBytes(at: 0x200, bytes: ARM64.pacibsp)
        patcher.buffer.writeBytes(at: 0x240, bytes: ARM64.pacibsp)
        let ready = KernelJBPatcher(data: patcher.buffer.data, verbose: false)
        ready.codeRanges = patcher.codeRanges
        ready.buildADRPIndex()
        let raw = ready.patchDiskImages2ClientAbi()
        #expect(raw == (connectPresent ? .matched : .encodeFail(reason: "incomplete DiskImages2 ABI patch")))
        #expect(ready.emittedRecords.count == (connectPresent ? 2 : 1))
        #expect(ready.buffer.readU32(at: 0x110) == ARM64.nopU32)
    }
}

extension KernelJBStructuredTests {
    @Test(arguments: [1, 2])
    func optionalVmProtectDoesNotHideAmbiguity(candidates: Int) throws {
        let fixture = KernelJBPatcher(data: Data(repeating: 0, count: 0x1000), verbose: false)
        fixture.buffer.writeBytes(at: 0x800, bytes: Data("vm_map_protect(\0".utf8))
        fixture.buffer.writeBytes(at: 0x100, bytes: ARM64.pacibsp)
        fixture.buffer.writeBytes(at: 0x104, bytes: try #require(ARM64Encoder.encodeADRP(rd: 0, pc: 0x104, target: 0x800)))
        fixture.buffer.writeBytes(at: 0x108, bytes: try #require(ARM64Encoder.encodeAddImm12(rd: 0, rn: 0, imm12: 0x800)))
        for off in [0x120, 0x160].prefix(candidates) {
            let target = off + 0x20
            fixture.buffer.writeBytes(at: off, bytes: try #require(ARM64Encoder.encodeMovzW(rd: 8, imm16: 6)))
            fixture.buffer.writeBytes(at: off + 4, bytes: ARM64.encodeU32(0x6A29_011F)) // bics wzr,w8,w9
            fixture.buffer.writeBytes(at: off + 8, bytes: try #require(ARM64Encoder.encodeBCond(.ne, from: off + 8, to: target)))
            fixture.buffer.writeBytes(at: off + 12, bytes: try #require(ARM64Encoder.encodeTestBitBranch(
                nonzero: true, register: 10, bit: 22, from: off + 12, to: target)))
            fixture.buffer.writeBytes(at: off + 16, bytes: ARM64.encodeU32(0x1200_0529)) // and w9,w9,#3
        }
        fixture.buffer.writeBytes(at: 0x200, bytes: ARM64.pacibsp)
        let patcher = KernelJBPatcher(data: fixture.buffer.data, verbose: false)
        patcher.codeRanges = [(0x100, 0x204)]
        patcher.buildADRPIndex()
        let raw = patcher.patchVmMapProtect()
        #expect(raw == (candidates == 1 ? .matched : .ambiguous(count: 2)))
        #expect(patcher.emittedRecords.count == (candidates == 1 ? 1 : 0))
        let outcome = PatchOutcomeMapping.outcome(for: raw, requirement: .optional, gates: Self.gates())
        #expect(outcome.kind == (candidates == 1 ? .applied : .failed))
    }
}
