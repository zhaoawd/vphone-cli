from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneCoreTests/CreateResourceSnapshotTests.swift'
s=p.read_text()
s=s.replace('        var storage: URL {', '        var rom: URL { root.appendingPathComponent("framework/boot-rom") }\n        var seprom: URL { root.appendingPathComponent("framework/sep-rom") }\n        var storage: URL {',1)
s=s.replace('            try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)', '''            try FileManager.default.createDirectory(at: rom.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rom-A".utf8).write(to: rom)
            try Data("sep-A".utf8).write(to: seprom)
            try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)''',1)
s=s.replace('storage: storage, availableBytes:', 'storage: storage, romSource: rom, sepromSource: seprom, availableBytes:',1)
s=s.replace('storage: f.storage,\n', 'storage: f.storage, romSource: f.rom, sepromSource: f.seprom,\n')
at=s.index('    @Test func capacityRefusalLeavesNoPartialSnapshotOrVMChanges()')
s=s[:at]+'''    // Catch omitting either live framework ROM from the captured bytes and identity.
    @Test func romCopiesAreManifestedAndIsolatedFromLiveReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.capture()
        try Data("rom-B".utf8).write(to: f.rom)
        try Data("sep-B".utf8).write(to: f.seprom)
        #expect(try String(contentsOf: snapshot.romSource, encoding: .utf8) == "rom-A")
        #expect(try String(contentsOf: snapshot.sepromSource, encoding: .utf8) == "sep-A")
        #expect(snapshot.manifest.entries.contains { $0.path == "ROMs/AVPBooter.vresearch1.bin" && $0.bytes == 5 && $0.sha256 != nil })
        #expect(snapshot.manifest.entries.contains { $0.path == "ROMs/AVPSEPBooter.vresearch1.bin" && $0.bytes == 5 && $0.sha256 != nil })
    }

    @Test(arguments: [false, true])
    func missingROMRefusesBeforeAnyMachineChanges(sep: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: sep ? f.seprom : f.rom)
        #expect(throws: Error.self) { try f.capture() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.machine.path).isEmpty)
        if FileManager.default.fileExists(atPath: f.storage.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        }
    }

    @Test func romChangesRequireExplicitResumeAcceptanceAndRetainEarlierOrigins() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try f.capture()
        let stages = Stages(); stages.fail = .cfw
        #expect(throws: VPhoneCreateRunError.self) {
            try runner(first, stages).create(bundleURL: f.machine, options: options, iphoneSource: nil, cloudosSource: nil)
        }
        let stored = try VPhoneCreateCheckpointStore.load(bundleURL: f.machine)
        try Data("rom-B".utf8).write(to: f.rom)
        let second = try f.capture()
        #expect(second.manifest.sha256 != first.manifest.sha256)
        stages.fail = nil
        #expect(throws: VPhoneCreateRunError.self) { try runner(second, stages).resume(bundleURL: f.machine) }
        #expect(try VPhoneCreateCheckpointStore.load(bundleURL: f.machine).data == stored.data)
        let resumed = try runner(second, stages).resume(bundleURL: f.machine, request: .init(acceptToolChange: true))
        #expect(resumed.attempts.last?.acceptedToolChange == true)
        #expect(resumed.record(.prepare).evidence["resource_snapshot_sha256"] == first.manifest.sha256)
        #expect(resumed.record(.cfw).evidence["resource_snapshot_sha256"] == second.manifest.sha256)
    }

    @Test func redirectedROMAfterInventoryIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("rom-original")
        let replacement = f.root.appendingPathComponent("rom-replacement")
        try Data("rom-A".utf8).write(to: original)
        try Data("rom-B".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: f.rom)
        try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: original)
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage,
                romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in
                    try FileManager.default.removeItem(at: f.rom)
                    try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: replacement)
                    return Int64.max
                })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

    @Test func romGrowthCannotWritePastItsAdmittedSize() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var observedTarget: FileHandle?
        defer { try? observedTarget?.close() }
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage,
                romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in Int64.max }, beforeCopy: { source, target in
                    guard source.path == f.rom.path else { return }
                    observedTarget = try FileHandle(forReadingFrom: target)
                    let writer = try FileHandle(forWritingTo: source)
                    defer { try? writer.close() }
                    try writer.seekToEnd()
                    try writer.write(contentsOf: Data(repeating: 0x42, count: 64 << 10))
                })
        }
        let target = try #require(observedTarget)
        #expect(try target.seekToEnd() <= 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

    @Test func romsCountAgainstCapacityAdmission() throws {
        let f = try Fixture(); defer { f.cleanup() }
        // Seven existing fixture inputs contain eight bytes each; the two ROMs add ten bytes.
        #expect(throws: Error.self) { try f.capture(capacity: 56 + (64 << 20)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

''' +s[at:]
p.write_text(s)
p=r/'tests/VPhoneCLITests/CreateResourceFreezeTests.swift'
s=p.read_text().replace('        init() throws {','        var rom: URL { root.appendingPathComponent("framework/boot-rom") }\n        var seprom: URL { root.appendingPathComponent("framework/sep-rom") }\n\n        init() throws {',1)
s=s.replace('            ] { try write(path, content) }','''            ] { try write(path, content) }
            try FileManager.default.createDirectory(at: rom.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rom-A".utf8).write(to: rom)
            try Data("sep-A".utf8).write(to: seprom)''',1)
s=s.replace('verbosity: .quiet, keepArtifacts: false))','verbosity: .quiet, keepArtifacts: false), romSource: rom, sepromSource: seprom)',1)
at=s.index('    // Catch reading the original source path')
s=s[:at]+'''    // Catch new/prepare consumers selecting live system ROMs after snapshot capture.
    @Test func newAndPrepareRefreshUseCapturedROMBytes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let runner = try f.runner()
        let selected = try #require(runner.executor as? VPhoneCreateLiveStages).orchestrator
        let snapshot = try #require(runner.resourceSnapshot)
        try Data("rom-B".utf8).write(to: f.rom)
        try Data("sep-B".utf8).write(to: f.seprom)
        let machine = try selected.createBundle(.init(name: "frozen", variant: "less", cpuCount: 2,
            memoryMB: 1024, diskSizeGB: 0), snapshot: snapshot)
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"), encoding: .utf8) == "rom-A")
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin"), encoding: .utf8) == "sep-A")
        try Data("patched".utf8).write(to: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try selected.refreshBootROM(bundleURL: machine.url)
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"), encoding: .utf8) == "rom-A")
    }

    @Test func createBundleWithoutSnapshotRefusesBeforeAllocatingDisk() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let orchestrator = VPhoneCreateOrchestrator(library: VPhoneLibrary(root: f.root.appendingPathComponent("library")),
            resources: f.resources, selfExecutable: f.executable)
        #expect(throws: Error.self) {
            try orchestrator.createBundle(.init(name: "missing", variant: "less", diskSizeGB: 0), snapshot: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/missing").path))
    }

''' +s[at:]
p.write_text(s)
