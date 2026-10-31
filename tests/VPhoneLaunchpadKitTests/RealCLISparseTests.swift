import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
@Suite(.serialized, .enabled(if: RealCLI.app != nil), .timeLimit(.minutes(5)))
struct RealCLISparseTests {
    private func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let block = try input.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test func nativeCLITransferPreservesSparseDiskAndHardlinks() throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lps")
        let source = try RealCLI.makeRoot(temp, "source")
        let destination = try RealCLI.makeRoot(temp, "destination")
        try RealCLI.newMachine("sparse", in: source, toolchain: toolchain)
        let original = URL(fileURLWithPath: source).appendingPathComponent("sparse")
        let disk = original.appendingPathComponent("Disk.img")
        let writer = try FileHandle(forWritingTo: disk)
        try writer.seek(toOffset: 512 << 20)
        try writer.write(contentsOf: Data(repeating: 0x42, count: 4096))
        try writer.close()
        let payload = original.appendingPathComponent("payload")
        try Data("hardlink payload".utf8).write(to: payload)
        try FileManager.default.linkItem(at: payload, to: original.appendingPathComponent("payload-copy"))
        let diskHash = try digest(disk)
        let archive = temp.url.appendingPathComponent("native.tzst")
        let exported = try LaunchpadProcess.run(toolchain.executable.path,
            ["vm", "export", "sparse", "--out", archive.path, "--library-root", source, "--archive-backend", "native"])
        try #require(exported.status == 0, "\(exported.output)")
        let archiveHash = try digest(archive)
        let imported = try LaunchpadProcess.run(toolchain.executable.path,
            ["vm", "import", archive.path, "--library-root", destination, "--archive-backend", "native"])
        try #require(imported.status == 0, "\(imported.output)")
        let restored = URL(fileURLWithPath: destination).appendingPathComponent("sparse")
        var a = stat(), b = stat(), first = stat(), second = stat()
        try #require(lstat(disk.path, &a) == 0 && lstat(restored.appendingPathComponent("Disk.img").path, &b) == 0)
        #expect(a.st_size == 1 << 30 && b.st_size == a.st_size)
        #expect(a.st_blocks * 512 < a.st_size / 2)
        #expect(b.st_blocks * 512 < b.st_size / 2)
        #expect(try digest(restored.appendingPathComponent("Disk.img")) == diskHash)
        #expect(try digest(disk) == diskHash)
        #expect(try digest(archive) == archiveHash)
        try #require(lstat(restored.appendingPathComponent("payload").path, &first) == 0
            && lstat(restored.appendingPathComponent("payload-copy").path, &second) == 0)
        #expect(first.st_ino == second.st_ino && first.st_nlink == 2)
        #expect(try Data(contentsOf: restored.appendingPathComponent("payload-copy")) == Data("hardlink payload".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination).allSatisfy { !$0.hasPrefix(".import-") })
        RealCLI.report("native sparse+hardlinks: 1GiB disk SHA preserved; source allocated \(a.st_blocks * 512), restored \(b.st_blocks * 512); two hardlinks share inode; archive unchanged")
    }
}
