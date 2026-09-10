import Foundation
import Testing
@testable import FirmwarePatcher

struct ArtifactStructuredTests {
    private func node(_ name: String, _ properties: [(String, Data)] = [], children: [Data] = []) -> Data {
        func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let props = [("name", Data((name + "\0").utf8))] + properties
        var data = word(UInt32(props.count)) + word(UInt32(children.count))
        for (key, value) in props {
            var header = Data(key.utf8)
            header.append(Data(repeating: 0, count: 32 - header.count))
            data += header + word(UInt32(value.count)) + value
            data += Data(repeating: 0, count: (4 - value.count % 4) % 4)
        }
        for child in children { data += child }
        return data
    }

    private var tree: Data {
        node("device-tree", [("serial-number", Data(repeating: 0, count: 12))], children: [
            node("buttons", [("home-button-type", Data(repeating: 0, count: 4))]),
            node("product", [("artwork-device-subtype", Data(repeating: 0, count: 4)),
                             ("island-notch-location", Data(repeating: 0, count: 4))]),
        ])
    }

    @Test func deviceTreeRebuildMatchesLegacyAndReportsIdempotence() throws {
        let old = DeviceTreePatcher(data: tree, verbose: false)
        let records = try old.findAll()
        _ = try old.apply()
        func run(_ data: Data) -> (report: ComponentReport, data: Data) {
            StructuredExecution.run(patcher: DeviceTreePatcher(data: data, verbose: false), componentName: "DeviceTree",
                gates: StructuredPatchResultTests.gates(), ablate: [], fallback: data)
        }
        let first = run(tree)
        #expect(first.report.records == records)
        #expect(first.data == old.patchedData)
        #expect(!first.report.hasRequiredFailure)
        let second = run(first.data)
        #expect(second.data == first.data)
        #expect(second.report.results.allSatisfy { $0.outcome == .alreadyApplied })
    }

    @Test func deviceTreeMissingPropertyDoesNotHideBehindSuccessfulProperties() {
        let data = node("device-tree", [("serial-number", Data(repeating: 0, count: 12))])
        let result = StructuredExecution.run(patcher: DeviceTreePatcher(data: data, verbose: false), componentName: "DeviceTree",
            gates: StructuredPatchResultTests.gates(), ablate: [], fallback: data)
        #expect(result.report.hasRequiredFailure)
        #expect(result.report.results.filter { $0.outcome == .applied }.count == 1)
        #expect(result.report.results.filter { $0.outcome == .failed }.count == 3)
    }

    @Test func deviceTreeAblationOmitsThePropertyDuringRebuild() {
        let result = StructuredExecution.run(patcher: DeviceTreePatcher(data: tree, verbose: false), componentName: "DeviceTree",
            gates: StructuredPatchResultTests.gates(), ablate: ["devicetree.DeviceTreePatcher.serial_number"], fallback: tree)
        #expect(!result.report.hasRequiredFailure)
        #expect(result.report.records.count == 3)
        #expect(result.data.range(of: Data("vphone-1337".utf8)) == nil)
    }

    @Test func filesystemFailureAndAblationProduceNoArtifacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for ablate: Set<String> in [[], ["filesystem"]] {
            let data = Data("invalid manifest".utf8)
            let p = CryptexFilesystemPatcher(buildManiest: data, restoreDir: dir, verbose: false)
            let result = StructuredExecution.run(patcher: p, componentName: "Filesystem",
                gates: StructuredPatchResultTests.gates(), ablate: ablate, fallback: data)
            #expect(result.report.results.first?.outcome == (ablate.isEmpty ? .failed : .ablated))
            #expect(result.report.records.isEmpty)
            #expect(result.data == data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        }
    }

    @Test func manifestHashStepRebuildsTheSameBytesAndReportsMissingInput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        try Data("fixture payload".utf8).write(to: file)
        let data = try PropertyListSerialization.data(fromPropertyList: ["BuildIdentities": [["Manifest": [
            "TestPayload": ["Info": ["Path": "payload.bin"]],
        ]]]], format: .xml, options: 0)
        let old = ManifestHashPatcher(data: data, restoreDir: dir, verbose: false)
        _ = try old.apply()
        func run() -> (report: ComponentReport, data: Data) {
            StructuredExecution.run(patcher: ManifestHashPatcher(data: data, restoreDir: dir, verbose: false),
                componentName: "Manifest", gates: StructuredPatchResultTests.gates(), ablate: [], fallback: data)
        }
        let result = run()
        #expect(!result.report.hasRequiredFailure)
        #expect(result.data == old.patchedData)
        #expect(result.report.records.first?.originalBytes == data)
        #expect(result.report.records.first?.patchedBytes == result.data)
        try FileManager.default.removeItem(at: file)
        #expect(run().report.hasRequiredFailure)
    }

    @Test func failedComponentStopsBeforeLaterInputsAndDevGateStaysActive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("FixtureRestore"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 0, count: 0x400)
        let input = dir.appendingPathComponent("AVPBooter.fixture.bin")
        try bytes.write(to: input)
        let pipeline = FirmwarePipeline(vmDirectory: dir, variant: .dev, verbose: false)
        // Later component inputs deliberately do not exist: accessing them would throw.
        let report = try pipeline.patchAllStructured()
        #expect(report.components.count == 1)
        #expect(!report.failedRequired.isEmpty)
        #expect(try Data(contentsOf: input) == bytes)
        #expect(report.gates.excGuardActive)
        let kernel = try #require(pipeline.buildComponentList().first { $0.name == "kernelcache" })
        let (_, results) = try pipeline.patchDataStructured(bytes, componentName: "kernelcache",
            patcherFactories: kernel.patcherFactories, gates: report.gates, ablate: [])
        #expect(results.first?.results.last?.outcome == .failed)
    }

    @Test(arguments: ["regular", "dev", "jb", "exp"], [false, true])
    func excGuardPipelineTruthTable(variant: String, ios18: Bool) throws {
        for force in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let restore = dir.appendingPathComponent("FixtureRestore")
            try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let manifest = try PropertyListSerialization.data(
                fromPropertyList: ["ProductVersion": ios18 ? "18.6.2" : "26.1"],
                format: .xml, options: 0)
            try manifest.write(to: restore.appendingPathComponent("iPhone-BuildManifest.plist"))
            let bytes = Data(repeating: 0, count: 0x400)
            try bytes.write(to: dir.appendingPathComponent("AVPBooter.fixture.bin"))
            let pipeline = FirmwarePipeline(vmDirectory: dir,
                variant: try #require(FirmwarePipeline.Variant(rawValue: variant)),
                verbose: false, forceExcGuard: force)
            // The first required failure returns a real prepare() snapshot before later I/O.
            let report = try pipeline.patchAllStructured()
            let active = variant == "dev" || ios18 || force
            #expect(report.gates.iosBaseIs18 == ios18)
            #expect(report.gates.forceExcGuard == force)
            #expect(report.gates.excGuardActive == active)
            let kernel = try #require(pipeline.buildComponentList().first { $0.name == "kernelcache" })
            let (_, reports) = try pipeline.patchDataStructured(bytes, componentName: "kernelcache",
                patcherFactories: kernel.patcherFactories, gates: report.gates, ablate: [])
            let result = try #require(reports.flatMap(\.results).first {
                $0.id.method == "patchExcGuardBehavior"
            })
            #expect(result.outcome == (active ? .failed : .notApplicable))
            #expect(result.rule == .excGuardActive)
        }
    }

    @Test func artifactStepsMatchManifest() throws {
        for variant in ["less", "regular", "dev", "jb", "exp"] {
            let p = DeviceTreePatcher(data: Data(), verbose: false, includeIdentityPatches: variant == "exp")
            let components = try C1AlignmentTests.components(variant: variant)
            let methods = try #require(components["DeviceTree"]?.methods)
            #expect(Set(p.buildSteps().map { $0.id.method }) == Set(methods.map(\.name)))
        }
        let less = try C1AlignmentTests.components(variant: "less")
        #expect(less["Filesystem"]?.methods.map(\.name) == [CryptexFilesystemPatcher.stepID.method])
        #expect(less["Manifest"]?.methods.map(\.name) == [ManifestHashPatcher.stepID.method])
    }

    @Test func lessDryRunRejectsFilesystemSideEffectsBeforeOpeningInputs() throws {
        let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: "/nonexistent/c3-test"), variant: .less, verbose: false)
        do {
            _ = try pipeline.patchAllStructured(ablate: ["devicetree"], allowOutput: false)
            Issue.record("less dry-run unexpectedly accepted filesystem side effects")
        } catch {
            #expect(String(describing: error).contains("less dry-run requires --ablate filesystem"))
        }
        let targets = pipeline.knownAblationTargets(pipeline.buildComponentList())
        #expect(targets.contains(CryptexFilesystemPatcher.stepID.description))
        #expect(targets.contains(ManifestHashPatcher.stepID.description))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_DT_IM4P"] != nil))
struct DeviceTreeStructuredParityTests {
    @Test(arguments: [false, true])
    func originalDeviceTreeParity(exp: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_TEST_DT_IM4P"])
        let payload = try IM4PHandler.load(contentsOf: URL(fileURLWithPath: path)).payload
        let old = DeviceTreePatcher(data: payload, verbose: false, includeIdentityPatches: exp)
        let records = try old.findAll()
        _ = try old.apply()
        let result = StructuredExecution.run(patcher: DeviceTreePatcher(data: payload, verbose: false, includeIdentityPatches: exp),
            componentName: "DeviceTree", gates: StructuredPatchResultTests.gates(), ablate: [], fallback: payload)
        #expect(!result.report.hasRequiredFailure)
        #expect(result.report.records == records)
        #expect(result.data == old.patchedData)
        print("C3 DeviceTree exp=\(exp): \(records.count) records; parity and completeness passed")
    }
}
