import CryptoKit
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
@Suite(.serialized, .enabled(if: RealCLI.app != nil), .timeLimit(.minutes(5)))
struct RealCLIImportQueueTests {
    private func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test func concurrentImportsPublishBothArchivesAndPreserveTheirSources() async throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lpi")
        let source = try RealCLI.makeRoot(temp, "source")
        let destination = try RealCLI.makeRoot(temp, "destination")
        let archiveRoot = URL(fileURLWithPath: try RealCLI.makeRoot(temp, "归档 files"))
        let names = ["first", "second"]
        var originals: [String: String] = [:]
        var archives: [URL] = []
        for name in names {
            try RealCLI.newMachine(name, in: source, toolchain: toolchain)
            let disk = URL(fileURLWithPath: source).appendingPathComponent(name).appendingPathComponent("Disk.img")
            let output = try FileHandle(forWritingTo: disk)
            try output.seek(toOffset: 4096)
            try output.write(contentsOf: Data(("fixture-" + name).utf8))
            try output.close()
            originals[name] = try digest(disk)
            let archive = archiveRoot.appendingPathComponent(name + ".tzst")
            let exported = try LaunchpadProcess.run(toolchain.executable.path,
                ["vm", "export", name, "--out", archive.path, "--library-root", source])
            try #require(exported.status == 0, "\(exported.output)")
            archives.append(archive)
        }
        let archiveHashes = try archives.map(digest)
        let history = VPhoneLaunchpadCommandHistory()
        let logs = URL(fileURLWithPath: destination).appendingPathComponent(".logs")
        let library = VPhoneLaunchpadMachineLibrary(defaults: InMemoryDefaults(), libraryRoot: destination, logsDirectory: logs)
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(
            executable: toolchain.executable, history: history, logsDirectory: logs, launcher: toolchain.launcher))
        library.stopMonitoring()
        let first = Task { await library.importArchive(archives[0]) }
        let second = Task { await library.importArchive(archives[1]) }
        await first.value
        await second.value
        #expect(history.entries.count == 2)
        #expect(history.entries.allSatisfy { $0.status == 0 && $0.outputDrained == true })
        #expect(library.machines.map(\.name).sorted() == names)
        #expect(library.imports.isEmpty)
        #expect(!library.hasActiveTransfers)
        #expect(library.actionError == nil)
        for name in names {
            let relative = name + "/Disk.img"
            #expect(try digest(URL(fileURLWithPath: source).appendingPathComponent(relative)) == originals[name])
            #expect(try digest(URL(fileURLWithPath: destination).appendingPathComponent(relative)) == originals[name])
        }
        #expect(try archives.map(digest) == archiveHashes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination)
        #expect(!leftovers.contains { $0.hasPrefix(".import-") })
        #expect(VPhoneLaunchpadQuit.decision(library) == .quit)
        let proof: [String: Any] = [
            "diskSHA256": originals,
            "archiveSHA256": Dictionary(uniqueKeysWithValues: zip(names, archiveHashes)),
            "statuses": history.entries.compactMap(\.status),
            "outputDrained": history.entries.allSatisfy { $0.outputDrained == true },
        ]
        RealCLI.report(String(decoding: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), as: UTF8.self))
        RealCLI.report("concurrent imports: both published, source/archive/full disk digests preserved; output drained")
    }

    @Test func terminationCancelsRealImportWithoutLaunchingItsWaitingArchive() async throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lpq")
        let source = try RealCLI.makeRoot(temp, "source")
        let destination = try RealCLI.makeRoot(temp, "destination")
        try RealCLI.newMachine("first", in: source, toolchain: toolchain)
        try RealCLI.newMachine("keep", in: destination, toolchain: toolchain)
        let sourceDisk = URL(fileURLWithPath: source).appendingPathComponent("first/Disk.img")
        let preservedConfig = URL(fileURLWithPath: destination).appendingPathComponent("keep/config.plist")
        let originalDisk = try digest(sourceDisk)
        let originalConfig = try digest(preservedConfig)
        let archive = temp.url.appendingPathComponent("first.tzst")
        let exported = try LaunchpadProcess.run(toolchain.executable.path,
            ["vm", "export", "first", "--out", archive.path, "--library-root", source])
        try #require(exported.status == 0, "\(exported.output)")
        let waitingArchive = temp.url.appendingPathComponent("waiting.tzst")
        try FileManager.default.copyItem(at: archive, to: waitingArchive)
        let originalArchive = try digest(archive)
        let history = VPhoneLaunchpadCommandHistory()
        let library = await RealCLI.library(destination, toolchain: toolchain, history: history)
        let batch = Task { await library.importArchives([archive, waitingArchive]) }
        defer { batch.cancel() }
        // Wait for the actual CLI's private extraction directory before cancelling.
        // This exercises its signal handler and cleanup after import has begun.
        try #require(await eventually {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
            return files.contains { $0.hasPrefix(".import-") }
                && library.imports.contains { $0.state == .waiting }
        }, "real import did not expose an active extraction and a waiting item")
        let command = try #require(library.currentCommandLine)
        #expect(VPhoneLaunchpadQuit.decision(library) == .drainCommands)
        #expect(command.beginTermination())
        library.cancelTransfers()
        #expect(await command.waitForTermination() == .drained)
        await batch.value
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.status == 130)
        #expect(history.entries.first?.outputDrained == true)
        #expect(!command.hasActiveCommands)
        #expect(!library.hasActiveTransfers)
        #expect(library.imports.isEmpty)
        #expect(library.actionError == nil)
        #expect(!RealCLI.exists(destination, "first"))
        #expect(try digest(sourceDisk) == originalDisk)
        #expect(try digest(preservedConfig) == originalConfig)
        #expect(try digest(archive) == originalArchive)
        #expect(try digest(waitingArchive) == originalArchive)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination)
        #expect(!leftovers.contains { $0.hasPrefix(".import-") })
        let processes = try LaunchpadProcess.run("/bin/ps", ["-axo", "pid=,command="])
        #expect(processes.status == 0)
        #expect(!processes.output.contains(archive.path))
        #expect(!processes.output.contains(waitingArchive.path))
        RealCLI.report("quit during real import: one child exited130, output drained, waiting archive not launched; sources and existing config preserved; no staging or child remains")
    }
}
