import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - The embedded vphone-cli, offline

/// Runs the B3 edits with the `vphone-cli` embedded in a built
/// `vphone-launchpad.app`, verified as the app verifies it, on fixtures that
/// `vm new` makes in temporary libraries. Nothing boots.
///
/// Opt-in, since it needs `make launchpad` first:
///
///     VPHONE_LAUNCHPAD_APP=$PWD/.build/vphone-launchpad.app \
///     VPHONE_LIBRARY_ROOT=<empty temporary folder> \
///     swift test --disable-sandbox --filter RealCLIEditTests
///
/// `VPHONE_LIBRARY_ROOT` must be set away from `~/.vphone/VMs`; every
/// command also names its temporary library with `--library-root`.
enum RealCLI {
    static let appKey = "VPHONE_LAUNCHPAD_APP"

    static var app: URL? {
        ProcessInfo.processInfo.environment[appKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The verified embedded toolchain; the default library must not be the
    /// user's.
    static func toolchain() throws -> VPhoneLaunchpadToolchain {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone/VMs").path
        let override = try #require(ProcessInfo.processInfo.environment["VPHONE_LIBRARY_ROOT"],
                                    "set VPHONE_LIBRARY_ROOT to a temporary folder")
        try #require(VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: override)) != VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: home)))
        return try VPhoneLaunchpadToolchain.verify(appBundle: try #require(app)).get()
    }

    /// `vm new <name> --library-root <root> --disk-size 1`, as fixture setup.
    static func newMachine(_ name: String, in root: String, toolchain: VPhoneLaunchpadToolchain) throws {
        let result = try LaunchpadProcess.run(toolchain.executable.path,
                                              ["vm", "new", name, "--library-root", root, "--disk-size", "1"])
        try #require(result.status == 0, "vm new failed: \(result.output)")
    }

    /// `vm info <name> --json`, read back after an edit.
    static func info(_ name: String, in root: String, toolchain: VPhoneLaunchpadToolchain) throws -> VPhoneLaunchpadMachine {
        let result = try LaunchpadProcess.run(toolchain.executable.path,
                                              ["vm", "info", name, "--json", "--library-root", root])
        try #require(result.status == 0, "vm info failed: \(result.output)")
        return try JSONDecoder().decode(VPhoneLaunchpadMachine.self, from: Data(result.output.utf8))
    }

    @MainActor
    static func library(_ root: String, toolchain: VPhoneLaunchpadToolchain, history: VPhoneLaunchpadCommandHistory) async -> VPhoneLaunchpadMachineLibrary {
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: root,
            logsDirectory: URL(fileURLWithPath: root).appendingPathComponent(".logs"),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(toolchain: toolchain, history: history))
        library.stopMonitoring()
        await library.refresh()
        return library
    }

    static func makeRoot(_ temp: LaunchpadTemporaryDirectory, _ name: String) throws -> String {
        let url = temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return VPhoneLaunchpadMachineLocations.canonical(url)
    }

    static func exists(_ root: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).appendingPathComponent("config.plist").path)
    }

    static func report(_ text: String) {
        FileHandle.standardOutput.write(Data("[real-cli] \(text)\n".utf8))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: RealCLI.app != nil), .timeLimit(.minutes(5)))
struct RealCLIEditTests {
    @Test func offlineEditsThroughTheEmbeddedCLI() async throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lpr")
        let l1 = try RealCLI.makeRoot(temp, "l1")
        let l2 = try RealCLI.makeRoot(temp, "l2")
        let out = URL(fileURLWithPath: try RealCLI.makeRoot(temp, "out"), isDirectory: true)
        try RealCLI.newMachine("a", in: l1, toolchain: toolchain)
        try RealCLI.newMachine("b", in: l1, toolchain: toolchain)
        let history = VPhoneLaunchpadCommandHistory()
        let library = await RealCLI.library(l1, toolchain: toolchain, history: history)
        let path = { VPhoneLaunchpadMachinePath(libraryRoot: l1, name: $0) }
        #expect(library.machines.map(\.name) == ["a", "b"])

        // Settings: only the edited fields.
        await library.configure([path("a")], .init(cpu: 2, memoryMB: 4096, network: "none"))
        var a = try RealCLI.info("a", in: l1, toolchain: toolchain)
        #expect(a.cpuCount == 2 && a.memoryMB == 4096 && a.network.mode == "none")
        await library.configure([path("a"), path("b")], .init(memoryMB: 3072))
        a = try RealCLI.info("a", in: l1, toolchain: toolchain)
        let b = try RealCLI.info("b", in: l1, toolchain: toolchain)
        #expect(a.cpuCount == 2 && a.memoryMB == 3072)
        #expect(b.cpuCount == 8 && b.memoryMB == 3072 && b.network.mode == "nat")

        // Rename and clone stay in the library.
        await library.rename(path("a"), to: "a2")
        #expect(!RealCLI.exists(l1, "a") && RealCLI.exists(l1, "a2"))
        #expect(library.selection == [path("a2")])
        await library.clone(path("a2"), as: "a3")
        #expect(RealCLI.exists(l1, "a2") && RealCLI.exists(l1, "a3"))
        #expect(try RealCLI.info("a3", in: l1, toolchain: toolchain).cpuCount == 2)
        #expect(library.machines.map(\.name) == ["a2", "a3", "b"])

        // Export one with a save-panel path, then two into a folder.
        let a3Archive = out.appendingPathComponent("a3.tzst")
        await library.export([(path("a3"), a3Archive)], densest: false, includeIPSW: false, replacing: true)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: a3Archive.path)[.size] as? Int)
        #expect(size > 0)
        await library.export([(path("a2"), out.appendingPathComponent("a2.tzst")), (path("b"), out.appendingPathComponent("b.tzst"))],
                             densest: false, includeIPSW: false, replacing: false)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("a2.tzst").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("b.tzst").path))
        #expect(library.exports.isEmpty)

        // Import into another library (its default), under the archive's name.
        let other = await RealCLI.library(l2, toolchain: toolchain, history: history)
        await other.importArchive(a3Archive)
        #expect(RealCLI.exists(l2, "a3"))
        #expect(other.machines.map(\.name) == ["a3"])
        #expect(try RealCLI.info("a3", in: l2, toolchain: toolchain).memoryMB == 3072)

        // Delete, only through vm delete.
        await library.delete([path("a3")])
        await other.delete([VPhoneLaunchpadMachinePath(libraryRoot: l2, name: "a3")])
        #expect(!RealCLI.exists(l1, "a3") && !RealCLI.exists(l2, "a3"))
        #expect(RealCLI.exists(l1, "a2") && RealCLI.exists(l1, "b"))
        #expect(library.machines.map(\.name) == ["a2", "b"])

        #expect(library.actionError == nil, "\(library.actionError?.message ?? ""): \(library.actionError?.detail ?? "")")
        #expect(other.actionError == nil)
        #expect(history.entries.allSatisfy { $0.status == 0 })
        let verbs = history.entries.map { $0.text.split(separator: " ").prefix(3).joined(separator: " ") }
        #expect(verbs == [
            "vphone-cli vm config", "vphone-cli vm config", "vphone-cli vm config", "vphone-cli vm rename",
            "vphone-cli vm clone", "vphone-cli vm export", "vphone-cli vm export", "vphone-cli vm export",
            "vphone-cli vm import", "vphone-cli vm delete", "vphone-cli vm delete",
        ])
        for entry in history.entries {
            RealCLI.report("history: \(entry.status.map(String.init) ?? "-") \(entry.text)")
        }
    }

    /// A stand-in lock holder takes the bundle lock as a running `vphone-vm`
    /// does. Launchpad sees no VM process and offers the edits; the CLI
    /// refuses each one, and the refusal is the error Launchpad shows.
    @Test func aHeldBundleLockIsRefusedAndShown() async throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lpr")
        let l1 = try RealCLI.makeRoot(temp, "l1")
        try RealCLI.newMachine("m", in: l1, toolchain: toolchain)
        let history = VPhoneLaunchpadCommandHistory()
        let library = await RealCLI.library(l1, toolchain: toolchain, history: history)
        let m = VPhoneLaunchpadMachinePath(libraryRoot: l1, name: "m")
        let archive = temp.url.appendingPathComponent("m.tzst")

        var holder: VPhoneVMLock? = try VPhoneVMLock(directory: m.url, operation: VPhoneVMOperation.boot)
        #expect(holder != nil)
        #expect(library.state(of: m) == .stopped)
        #expect(library.canEdit(m))

        var shown: [String] = []
        func take() -> VPhoneLaunchpadError? {
            defer { library.actionError = nil }
            if let error = library.actionError {
                shown.append("\(error.message) | \(error.detail ?? "")")
            }
            return library.actionError
        }
        await library.configure([m], .init(cpu: 2))
        let configError = try #require(take())
        #expect(configError.message == "Unable to Save Settings for m")
        #expect(configError.detail?.contains("busy") == true)
        await library.rename(m, to: "m2")
        #expect(take()?.message == "Unable to Rename m")
        await library.clone(m, as: "m-copy")
        #expect(take()?.message == "Unable to Clone m")
        await library.export([(m, archive)], densest: false, includeIPSW: false, replacing: false)
        #expect(take()?.message == "Unable to Export m")
        await library.delete([m])
        #expect(take()?.message == "Unable to Delete m")

        #expect(RealCLI.exists(l1, "m") && !RealCLI.exists(l1, "m2") && !RealCLI.exists(l1, "m-copy"))
        #expect(try RealCLI.info("m", in: l1, toolchain: toolchain).cpuCount == 8)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(history.entries.count == 5)
        #expect(history.entries.allSatisfy { ($0.status ?? 0) != 0 })
        for text in shown {
            RealCLI.report("refusal: \(text)")
        }
        #expect(shown.allSatisfy { $0.contains("busy") })

        holder = nil
        await library.configure([m], .init(cpu: 2))
        #expect(library.actionError == nil)
        #expect(try RealCLI.info("m", in: l1, toolchain: toolchain).cpuCount == 2)
    }

    /// Cancel sends SIGINT to `vm export`; the partial archive it created is
    /// removed and stays gone, and the bundle lock is free again.
    @Test func cancellingARealExportRemovesItsPartialArchive() async throws {
        let toolchain = try RealCLI.toolchain()
        let temp = try LaunchpadTemporaryDirectory(short: "lpr")
        let l1 = try RealCLI.makeRoot(temp, "l1")
        try RealCLI.newMachine("c", in: l1, toolchain: toolchain)
        let c = VPhoneLaunchpadMachinePath(libraryRoot: l1, name: "c")
        // Incompressible data, so `xz -9` keeps the export busy for seconds.
        let dd = try LaunchpadProcess.run("/bin/dd", ["if=/dev/urandom", "of=\(c.url.appendingPathComponent("Disk.img").path)",
                                                       "bs=1m", "count=192", "conv=notrunc"])
        try #require(dd.status == 0, "dd failed: \(dd.output)")
        let history = VPhoneLaunchpadCommandHistory()
        let library = await RealCLI.library(l1, toolchain: toolchain, history: history)
        let archive = temp.url.appendingPathComponent("c.txz")

        let started = Date()
        let export = Task { await library.export([(c, archive)], densest: true, includeIPSW: false, replacing: false) }
        #expect(await eventually(60) { ((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0) > 0 })
        // Mid-export, not at the first bytes.
        try await Task.sleep(for: .seconds(2))
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        let cancelledAfter = Date().timeIntervalSince(started)
        #expect(library.isExporting(c))
        library.cancelExport(c)
        await export.value
        RealCLI.report(String(format: "export cancelled %.1f s after start at %d bytes; status %@", cancelledAfter, size,
                              history.entries.last?.status.map(String.init) ?? "-"))

        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(library.actionError == nil)
        #expect(history.entries.last?.status == SIGINT)
        // The tar processes `vm export` started end once their pipe closes;
        // none recreates the file.
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        let ps = try LaunchpadProcess.run("/bin/ps", ["-axo", "pid=,command="])
        #expect(!ps.output.contains(archive.path))

        await library.configure([c], .init(cpu: 3))
        #expect(library.actionError == nil)
        #expect(try RealCLI.info("c", in: l1, toolchain: toolchain).cpuCount == 3)
    }
}
