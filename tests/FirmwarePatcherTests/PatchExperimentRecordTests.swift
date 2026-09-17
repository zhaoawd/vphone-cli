import Darwin
import Foundation
import Testing
@testable import FirmwarePatcher

/// C5 no-VM record tests: synthetic VM directories, a pass-through loader and injected
/// environment facts. Real patchers run only where a required failure is intended.
@Suite struct PatchExperimentRecordTests {
    static let restoreName = "iPhone17,3_26.1_23B85_Restore"
    static let allComponents = ["avpbooter", "ibss", "ibec", "llb", "txm", "kernelcache", "devicetree"]

    // MARK: - Fixtures

    final class Fixture {
        let fm = FileManager.default
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c5-" + UUID().uuidString)
        var vm: URL { root.appendingPathComponent("vm") }
        var restore: URL { vm.appendingPathComponent(PatchExperimentRecordTests.restoreName) }
        var recordURL: URL { root.appendingPathComponent("record.json") }
        var kernel: URL { restore.appendingPathComponent("kernelcache.research.vphone600") }

        init() throws {
            let files = [
                "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p", "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
                "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p", "Firmware/txm.iphoneos.research.im4p",
                "kernelcache.research.vphone600", "Firmware/all_flash/DeviceTree.vphone600ap.im4p",
            ]
            for file in files {
                let url = restore.appendingPathComponent(file)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 256).write(to: url)
            }
            try Data(repeating: 0x42, count: 128).write(to: vm.appendingPathComponent("AVPBooter.vresearch1.bin"))
            try manifest(["ProductVersion": "26.1", "ProductBuildVersion": "23B85"], "iPhone-BuildManifest.plist")
            try manifest(["ProductVersion": "26.1", "ProductBuildVersion": "23B5046f"], "BuildManifest.plist")
        }
        deinit { try? fm.removeItem(at: root) }

        func manifest(_ values: [String: String], _ name: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: restore.appendingPathComponent(name))
        }

        func environment(hook: @escaping (URL, PatchExperimentRecord.WriteStep) throws -> Void = { _, _ in },
                         diagnostics: @escaping (String) -> Void = { _ in }) -> PatchExperimentEnvironment {
            PatchExperimentEnvironment(
                buildCommit: "fixture", executable: nil, sourceRoot: nil, resourcesBase: nil, sealDirectory: nil,
                pythonExecutable: { throw POSIXError(.ENOENT) },
                writeHook: hook, diagnostics: diagnostics)
        }

        @discardableResult
        func run(variant: FirmwarePipeline.Variant = .regular, forceExcGuard: Bool = false,
                 ablate: [String] = PatchExperimentRecordTests.allComponents, allowOutput: Bool = true,
                 loader: any FirmwarePipeline.FirmwareLoader = PassThroughLoader(),
                 hook: @escaping (URL, PatchExperimentRecord.WriteStep) throws -> Void = { _, _ in },
                 diagnostics: @escaping (String) -> Void = { _ in }) throws -> PatchRunReport {
            let pipeline = FirmwarePipeline(vmDirectory: vm, variant: variant, verbose: false,
                                            forceExcGuard: forceExcGuard, loader: loader)
            return try PatchExperimentRecorder(recordURL: recordURL, environment: environment(hook: hook, diagnostics: diagnostics))
                .run(pipeline, ablate: ablate, allowOutput: allowOutput)
        }

        func record() throws -> PatchExperimentRecord { try PatchExperimentRecord.load(from: recordURL) }
    }

    struct PassThroughLoader: FirmwarePipeline.FirmwareLoader {
        func load(from url: URL) throws -> Data { try Data(contentsOf: url) }
        func save(_ data: Data, to url: URL) throws { try data.write(to: url) }
    }

    /// Cancels when the named component file is loaded.
    struct CancellingLoader: FirmwarePipeline.FirmwareLoader {
        let file: String
        func load(from url: URL) throws -> Data {
            if url.lastPathComponent == file { throw CancellationError() }
            return try Data(contentsOf: url)
        }
        func save(_ data: Data, to url: URL) throws { try data.write(to: url) }
    }

    /// Paths that may differ between runs without changing the three comparison results.
    static let excludedPrefixes = ["runID", "startedAt", "finishedAt", "error", "transaction.", "run."]

    // MARK: - Identical and Changed Conditions

    @Test func identicalRunsInDifferentDirectoriesCompareSame() throws {
        let a = try Fixture(), b = try Fixture()
        try a.run(); try b.run()
        let left = try a.record(), right = try b.record()
        #expect(left.status == .succeeded)
        #expect(left.transaction.state == "committed")
        #expect(left.outputs.availability == "available")
        #expect(left.conditions.firmware.iPhone.buildVersion.value == "23B85")
        #expect(left.conditions.firmware.cloudOS.buildVersion.value == "23B5046f")
        #expect(left.conditions.firmware.origin.value == nil && left.conditions.firmware.origin.reason != nil)

        let comparison = try PatchExperimentRecord.compare(left, right)
        #expect(comparison.conditions.result == .same)
        #expect(comparison.patchResults.result == .same)
        #expect(comparison.artifacts.result == .same)
        #expect(comparison.allSame)
        #expect(left.conditionDigest == right.conditionDigest)
        let excluded = comparison.excluded.map(\.path)
        #expect(excluded.contains("runID"))
        #expect(excluded.contains("run.vmDirectory"))
        #expect(excluded.allSatisfy { path in Self.excludedPrefixes.contains { path.hasPrefix($0) } })
    }

    enum Change: String, CaseIterable { case variant, forceExcGuard, ablation, inputByte }

    @Test(arguments: Change.allCases) func changedConditionIsNamed(_ change: Change) throws {
        let a = try Fixture(), b = try Fixture()
        try a.run()
        switch change {
        case .variant: try b.run(variant: .dev)
        case .forceExcGuard: try b.run(forceExcGuard: true)
        case .ablation: try b.run(ablate: Self.allComponents + ["kernelcache.KernelPatcher"])
        case .inputByte:
            let handle = try FileHandle(forWritingTo: b.kernel)
            try handle.seek(toOffset: 17); try handle.write(contentsOf: Data([0x00])); try handle.close()
            try b.run()
        }
        let comparison = try PatchExperimentRecord.compare(try a.record(), try b.record())
        let paths = comparison.conditions.differences.map(\.path)
        #expect(comparison.conditions.result == .different)
        let kernelPath = "\(Self.restoreName)/kernelcache.research.vphone600"
        switch change {
        case .variant: #expect(paths == ["conditions.options.variant"])
        case .forceExcGuard:
            #expect(paths == ["conditions.options.forceExcGuard"])
            // The gate snapshot inside the existing report records the option as well.
            #expect(comparison.patchResults.differences.contains { $0.path.hasSuffix("gates.forceExcGuard") })
        case .ablation: #expect(paths == ["conditions.options.ablate"])
        case .inputByte:
            #expect(paths.contains("conditions.inputs.files[\(kernelPath)].digest"))
            #expect(paths.contains("conditions.inputs.roots[\(Self.restoreName)].digest"))
            #expect(paths.allSatisfy { $0.hasPrefix("conditions.inputs.") })
            #expect(comparison.artifacts.result == .different)
        }
    }

    // MARK: - Failure and Cancellation

    @Test func requiredFailureAfterPartialSuccessKeepsCompletedParts() throws {
        let f = try Fixture()
        let report = try f.run(ablate: ["avpbooter"])
        #expect(!report.failedRequired.isEmpty)
        let record = try f.record()
        #expect(record.status == .failed)
        #expect(record.failedStage?.stage == "patch")
        #expect(record.failedStage?.component == "iBSS")
        #expect(record.patch.processedComponents == ["AVPBooter", "iBSS"])
        #expect(record.patch.notRunComponents.first == "iBEC")
        #expect(record.patch.failedRequired == report.failedRequired.map(\.description))
        #expect(record.patch.report == report)
        #expect(record.transaction.state == "uncommitted")
        #expect(record.outputs.availability == "unavailable")
        #expect(record.outputs.files.isEmpty)
        #expect(try String(contentsOf: PatchExperimentRecord.summaryURL(for: f.recordURL), encoding: .utf8) == record.summary())
    }

    @Test func cancellationAfterPartialSuccessKeepsOriginalError() throws {
        let f = try Fixture()
        #expect(throws: CancellationError.self) {
            try f.run(loader: CancellingLoader(file: "iBSS.vresearch101.RELEASE.im4p"))
        }
        let record = try f.record()
        #expect(record.status == .cancelled)
        #expect(record.failedStage?.stage == "patch")
        #expect(record.failedStage?.component == "iBSS")
        #expect(record.patch.processedComponents == ["AVPBooter"])
        #expect(record.patch.report?.components.map(\.component) == ["AVPBooter"])
        #expect(record.patch.report?.components.first?.results.allSatisfy { $0.outcome == .ablated } == true)
        #expect(record.patch.reason?.contains("partial") == true)
        #expect(!record.patch.notRunComponents.contains("AVPBooter"))
        #expect(record.transaction.state == "uncommitted")
        #expect(record.outputs.availability == "unavailable")
    }

    // MARK: - Record Write Failures

    final class WriteCounter {
        var records = 0
        var summaries = 0
    }

    static let injected: [(PatchExperimentRecord.WriteStep, POSIXErrorCode)] = [
        (.write, .ENOSPC), (.fsync, .EIO), (.rename, .EXDEV), (.syncDirectory, .EIO),
    ]

    @Test(arguments: 0..<4) func finalWriteFailureDoesNotMaskRunError(_ index: Int) throws {
        let (step, code) = Self.injected[index]
        let f = try Fixture()
        let counter = WriteCounter()
        var messages: [String] = []
        let hook: (URL, PatchExperimentRecord.WriteStep) throws -> Void = { url, current in
            guard url == f.recordURL else { return }
            if current == .create { counter.records += 1 }
            if counter.records == 2, current == step { throw POSIXError(code) }
        }
        #expect(throws: CancellationError.self) {
            try f.run(loader: CancellingLoader(file: "iBSS.vresearch101.RELEASE.im4p"), hook: hook,
                      diagnostics: { messages.append($0) })
        }
        #expect(messages.count == 1)
        try expectNoCompleteRecord(f)
    }

    @Test(arguments: 0..<4) func finalWriteFailureAfterSuccessIsReported(_ index: Int) throws {
        let (step, code) = Self.injected[index]
        let f = try Fixture()
        let counter = WriteCounter()
        let hook: (URL, PatchExperimentRecord.WriteStep) throws -> Void = { url, current in
            guard url == f.recordURL else { return }
            if current == .create { counter.records += 1 }
            if counter.records == 2, current == step { throw POSIXError(code) }
        }
        #expect(throws: POSIXError.self) { try f.run(hook: hook) }
        try expectNoCompleteRecord(f)
        // No leftover temporary files next to the record.
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(!names.contains { $0.contains(".tmp-") })
    }

    @Test func initialWriteFailureStopsBeforePatching() throws {
        let f = try Fixture()
        let hook: (URL, PatchExperimentRecord.WriteStep) throws -> Void = { _, step in
            if step == .write { throw POSIXError(.ENOSPC) }
        }
        #expect(throws: POSIXError.self) { try f.run(hook: hook) }
        #expect(!FileManager.default.fileExists(atPath: f.recordURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-history").path))
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-transaction").path))
    }

    @Test func recordInsideFirmwareInputIsRejectedBeforePatching() throws {
        let f = try Fixture()
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false, loader: PassThroughLoader())
        let inside = f.restore.appendingPathComponent("record.json")
        #expect(throws: PatchExperimentRecordError.self) {
            try PatchExperimentRecorder(recordURL: inside, environment: f.environment())
                .run(pipeline, ablate: Self.allComponents, allowOutput: true)
        }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(!FileManager.default.fileExists(atPath: f.vm.appendingPathComponent(".firmware-history").path))
    }

    private func expectNoCompleteRecord(_ f: Fixture) throws {
        #expect(!FileManager.default.fileExists(atPath: PatchExperimentRecord.summaryURL(for: f.recordURL).path))
        guard FileManager.default.fileExists(atPath: f.recordURL.path) else { return }
        let record = try f.record()
        #expect(record.status == .running)
        #expect(record.finishedAt == nil)
        #expect(record.outputs.availability == "pending")
    }

    // MARK: - Validation

    @Test func corruptAndUnknownRecordsAreRejected() throws {
        let f = try Fixture()
        try f.run()
        let data = try Data(contentsOf: f.recordURL)
        _ = try PatchExperimentRecord.decode(data)

        func mutated(_ body: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            body(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }
        func nested(_ object: inout [String: Any], _ keys: [String], _ value: Any) {
            guard let key = keys.first else { return }
            if keys.count == 1 { object[key] = value; return }
            var child = object[key] as? [String: Any] ?? [:]
            nested(&child, Array(keys.dropFirst()), value)
            object[key] = child
        }

        let cases: [Data] = [
            data.prefix(data.count / 2),
            try mutated { $0["schemaVersion"] = 2 },
            try mutated { $0["schema"] = "other" },
            try mutated { $0.removeValue(forKey: "finishedAt") },
            try mutated { nested(&$0, ["conditions", "options", "forceExcGuard"], true) },
            try mutated { nested(&$0, ["patch", "failedRequired"], ["ibss.IBootPatcher.patchImageLoader"]) },
            try mutated { nested(&$0, ["conditions", "tool", "hostOS", "reason"], "both value and reason") },
            try mutated { $0["status"] = "failed" },
        ]
        for (index, bytes) in cases.enumerated() {
            #expect(throws: PatchExperimentRecordError.self, "case \(index)") { try PatchExperimentRecord.decode(bytes) }
        }
        #expect(throws: PatchExperimentRecordError.self) {
            try PatchExperimentRecord.decode(try mutated { $0["schemaVersion"] = 2 })
        }
    }

    @Test func uncommittedTransactionIsNotSuccessfulOutput() throws {
        let f = try Fixture()
        try f.run(ablate: Self.allComponents, allowOutput: false)
        let dryRun = try f.record()
        #expect(dryRun.status == .succeeded)
        #expect(dryRun.transaction.state == "none")
        #expect(dryRun.outputs.availability == "unavailable")

        // A trace whose transaction was staged but never committed.
        let pipeline = FirmwarePipeline(vmDirectory: f.vm, verbose: false)
        let transaction = try FirmwareTransaction(vmDirectory: f.vm, inputs: try pipeline.transactionRoots(),
                                                  options: ["variant": "regular"], mounts: { _, _ in })
        let trace = FirmwareRunTrace()
        trace.transaction = transaction
        trace.stage = .commit
        let record = PatchExperimentRecorder.finish(dryRun, trace: trace, vmDirectory: f.vm, report: dryRun.patch.report,
                                                    error: nil, finishedAt: dryRun.finishedAt!)
        #expect(record.status == .failed)
        #expect(record.failedStage?.stage == "commit")
        #expect(record.transaction.state == "uncommitted")
        #expect(record.transaction.journal?.phase == .building)
        #expect(record.outputs.availability == "unavailable")
        try record.validate()

        var forged = record
        forged.status = .succeeded; forged.failedStage = nil; forged.error = nil
        #expect(throws: PatchExperimentRecordError.self) { try forged.validate() }
        forged = record
        forged.transaction.state = "committed"
        #expect(throws: PatchExperimentRecordError.self) { try forged.validate() }
        forged = record
        forged.outputs = dryRun.conditions.inputs
        #expect(throws: PatchExperimentRecordError.self) { try forged.validate() }
    }

    @Test func summaryIsRenderedFromTheRecord() throws {
        let f = try Fixture()
        try f.run()
        let record = try f.record()
        let summary = try String(contentsOf: PatchExperimentRecord.summaryURL(for: f.recordURL), encoding: .utf8)
        #expect(summary == record.summary())
        #expect(summary.contains("status:     succeeded"))
        #expect(summary.contains("23B85"))
        #expect(summary.contains("transaction: committed"))
        #expect(PatchExperimentRecord.summaryURL(for: URL(fileURLWithPath: "/x/run.json")).lastPathComponent == "run.summary.txt")
    }

    // MARK: - Source State

    @Test func sourceStateListsChangedAddedAndDeletedFiles() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("c5-git-" + UUID().uuidString)
        defer { try? fm.removeItem(at: repo) }
        try fm.createDirectory(at: repo.appendingPathComponent("sources"), withIntermediateDirectories: true)
        try Data("// package".utf8).write(to: repo.appendingPathComponent("Package.swift"))
        try Data("let a = 1".utf8).write(to: repo.appendingPathComponent("sources/a.swift"))
        try Data("let b = 1".utf8).write(to: repo.appendingPathComponent("sources/b.swift"))
        try Data("notes".utf8).write(to: repo.appendingPathComponent("README.md"))
        func git(_ args: String...) throws {
            let result = try FirmwareTransaction.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@example.invalid"] + args)
            _ = result
        }
        try git("init", "-q"); try git("add", "."); try git("commit", "-q", "-m", "init")

        var environment = PatchExperimentEnvironment(buildCommit: nil, executable: nil, sourceRoot: repo, resourcesBase: nil,
                                                     sealDirectory: nil, pythonExecutable: { throw POSIXError(.ENOENT) })
        let recorder = PatchExperimentRecorder(recordURL: repo.appendingPathComponent("r.json"), environment: environment)
        let clean = recorder.collectSource()
        #expect(clean.status == "clean")
        #expect(clean.commit?.count == 40)

        try Data("let a = 2".utf8).write(to: repo.appendingPathComponent("sources/a.swift"))
        try fm.removeItem(at: repo.appendingPathComponent("sources/b.swift"))
        try Data("let c = 1".utf8).write(to: repo.appendingPathComponent("sources/c.swift"))
        try Data("outside scope".utf8).write(to: repo.appendingPathComponent("README.md"))
        let dirty = recorder.collectSource()
        #expect(dirty.status == "dirty")
        #expect(dirty.changes.map(\.path) == ["sources/a.swift", "sources/b.swift", "sources/c.swift"])
        #expect(dirty.changes.map(\.state) == ["M", "D", "??"])
        #expect(dirty.changes[0].sha256 == PatchExperimentRecord.sha256(Data("let a = 2".utf8)))
        #expect(dirty.changes[1].sha256 == nil && dirty.changes[1].reason != nil)

        environment.sourceRoot = nil
        let unavailable = PatchExperimentRecorder(recordURL: repo.appendingPathComponent("r.json"), environment: environment).collectSource()
        #expect(unavailable.status == "unavailable" && unavailable.reason != nil)
    }
}
