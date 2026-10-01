import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - Argument construction

@Suite struct EditCommandTests {
    let path = VPhoneLaunchpadMachinePath(libraryRoot: "/lib", name: "m1")
    typealias Command = VPhoneLaunchpadEditCommand
    typealias Settings = VPhoneLaunchpadEditCommand.Settings

    @Test func configPassesOnlyEditedFields() {
        #expect(Command.config(path, Settings(cpu: 4))?.arguments
            == ["vm", "config", "m1", "--library-root", "/lib", "--cpu", "4"])
        #expect(Command.config(path, Settings(cpu: 2, memoryMB: 4096, network: "none"))?.arguments
            == ["vm", "config", "m1", "--library-root", "/lib", "--cpu", "2", "--memory", "4096", "--network", "none"])
        #expect(Command.config(path, Settings(network: "bridged", bridgeInterface: "en0"))?.arguments
            == ["vm", "config", "m1", "--library-root", "/lib", "--network", "bridged", "--bridge-interface", "en0"])
        // An empty interface lets vphone-cli pick the first one.
        #expect(Command.config(path, Settings(network: "bridged", bridgeInterface: ""))?.arguments
            == ["vm", "config", "m1", "--library-root", "/lib", "--network", "bridged"])
        #expect(Command.config(path, Settings(network: "nat"))?.kind == .config)
    }

    @Test func configRejectsWhatVMConfigWouldNot() {
        #expect(Command.config(path, Settings()) == nil)
        #expect(Command.config(path, Settings(cpu: 0)) == nil)
        #expect(Command.config(path, Settings(memoryMB: -1)) == nil)
        #expect(Command.config(path, Settings(network: "hostOnly")) == nil)
        #expect(Command.config(path, Settings(cpu: 2, bridgeInterface: "en0")) == nil)
        #expect(Command.config(path, Settings(network: "nat", bridgeInterface: "en0")) == nil)
        #expect(Command.config(path, Settings(network: "bridged", bridgeInterface: "-x")) == nil)
        #expect(Command.config(path, Settings(network: "bridged", bridgeInterface: "en0 en1")) == nil)
    }

    @Test func renameAndCloneStayInTheLibrary() {
        #expect(Command.rename(path, to: "m2")?.arguments == ["vm", "rename", "m1", "m2", "--library-root", "/lib"])
        #expect(Command.clone(path, as: "m1-clone")?.arguments == ["vm", "clone", "m1", "m1-clone", "--library-root", "/lib"])
    }

    @Test(arguments: ["", "m1", "-m2", ".m2", "m/2", "a..b", "m 2", String(repeating: "a", count: 65), "ü"])
    func newNamesOutsideThePatternAreRejected(_ name: String) {
        #expect(Command.rename(path, to: name) == nil)
        #expect(Command.clone(path, as: name) == nil)
    }

    @Test func newNameMustFitTheSocketPath() {
        let deep = VPhoneLaunchpadMachinePath(libraryRoot: "/" + String(repeating: "d", count: 80), name: "m1")
        #expect(!VPhoneLaunchpadMachineLocations.socketPathFits(root: deep.libraryRoot, name: "a-twenty-char-name-x"))
        #expect(Command.rename(deep, to: "a-twenty-char-name-x") == nil)
        #expect(Command.rename(deep, to: "m2") != nil)
        // 104 bytes of sun_path, including the terminating NUL.
        let root = "/" + String(repeating: "r", count: 103 - "/m/vphone.sock".count - 1)
        #expect(VPhoneLaunchpadMachineLocations.socketPathFits(root: root, name: "m"))
        #expect(!VPhoneLaunchpadMachineLocations.socketPathFits(root: root, name: "mm"))
    }

    @Test func deletePassesForceAndTheLibrary() {
        #expect(Command.delete(path)?.arguments == ["vm", "delete", "m1", "--force", "--library-root", "/lib"])
    }

    @Test func exportAndImport() {
        let out = URL(fileURLWithPath: "/out dir/m1.tzst")
        #expect(Command.export(path, to: out, densest: false, includeIPSW: false)?.arguments
            == ["vm", "export", "m1", "--out", "/out dir/m1.tzst", "--library-root", "/lib"])
        #expect(Command.export(path, to: out, densest: true, includeIPSW: true)?.arguments
            == ["vm", "export", "m1", "--out", "/out dir/m1.tzst", "--library-root", "/lib", "--max", "--include-ipsw"])
        #expect(Command.export(path, to: out, densest: false, includeIPSW: false)?.display
            == "vphone-cli vm export m1 --out '/out dir/m1.tzst' --library-root /lib")
        #expect(Command.importArchive(URL(fileURLWithPath: "/a/m1.tzst"), into: "/lib")?.arguments
            == ["vm", "import", "/a/m1.tzst", "--library-root", "/lib"])
        #expect(Command.importArchive(URL(string: "https://example.invalid/m1.tzst")!, into: "/lib") == nil)
        #expect(Command.importArchive(URL(fileURLWithPath: "/a/m1.tzst"), into: "lib") == nil)
        #expect(Command.export(path, to: URL(string: "https://example.invalid/m1.tzst")!, densest: false, includeIPSW: false) == nil)
    }

    /// `vm list` lists any folder with a config.plist; a name that would be
    /// read as an option, or a relative library, is never passed.
    @Test(arguments: ["-m", "--help", ".hidden", "a/b", "", "a\nb"])
    func unpassableMachinesAreRefused(_ name: String) {
        let odd = VPhoneLaunchpadMachinePath(libraryRoot: "/lib", name: name)
        #expect(Command.config(odd, Settings(cpu: 2)) == nil)
        #expect(Command.rename(odd, to: "ok") == nil)
        #expect(Command.clone(odd, as: "ok") == nil)
        #expect(Command.delete(odd) == nil)
        #expect(Command.export(odd, to: URL(fileURLWithPath: "/o.tzst"), densest: false, includeIPSW: false) == nil)
        #expect(Command.delete(VPhoneLaunchpadMachinePath(libraryRoot: "lib", name: "m1")) == nil)
    }

    @Test func existingNamesLikeTheCLIAcceptsArePassed() {
        // vphone-cli accepts any name without "/" or a leading "."; a space is
        // passed as one argument.
        let spaced = VPhoneLaunchpadMachinePath(libraryRoot: "/lib", name: "my vm")
        #expect(Command.delete(spaced)?.arguments == ["vm", "delete", "my vm", "--force", "--library-root", "/lib"])
    }
}

// MARK: - Cancelled export output

@Suite struct ExportOutputTests {
    @Test func onlyAFileTheExportCreatedIsRemoved() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-export-output")
        let file = temp.url.appendingPathComponent("m.tzst")
        let fm = FileManager.default

        #expect(!VPhoneLaunchpadExportOutput.exists(file))
        #expect(!VPhoneLaunchpadExportOutput.removeCancelled(file, existedBefore: false))

        fm.createFile(atPath: file.path, contents: Data("partial".utf8))
        #expect(!VPhoneLaunchpadExportOutput.removeCancelled(file, existedBefore: true))
        #expect(fm.fileExists(atPath: file.path))
        #expect(VPhoneLaunchpadExportOutput.removeCancelled(file, existedBefore: false))
        #expect(!fm.fileExists(atPath: file.path))

        // A folder or a link at the path is never removed, nor what a link names.
        let folder = temp.url.appendingPathComponent("folder.tzst")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(!VPhoneLaunchpadExportOutput.removeCancelled(folder, existedBefore: false))
        let target = temp.url.appendingPathComponent("target")
        fm.createFile(atPath: target.path, contents: Data("keep".utf8))
        let link = temp.url.appendingPathComponent("link.tzst")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(VPhoneLaunchpadExportOutput.exists(link))
        #expect(!VPhoneLaunchpadExportOutput.removeCancelled(link, existedBefore: false))
        #expect(fm.fileExists(atPath: folder.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }
}

// MARK: - Stand-in vphone-cli for edits

/// A shell script in place of `vphone-cli` for `vm list` and the edits.
/// Every call appends its arguments to `arguments.log`.
///
/// - `vm list` prints `<root>/.list.json`.
/// - `config`, `rename`, `clone`, `delete`, `import`: when
///   `<root>/<name>.busy` exists, prints the CLI's busy refusal to stderr and
///   exits 1; otherwise prints one line and exits 0.
/// - `export`: the same refusal; otherwise creates the `--out` file and
///   appends a line every 0.1 s for 3 s, or at once when `<root>/.fast`
///   exists. SIGINT ends it with status 130.
@MainActor
struct LaunchpadEditStandIn {
    let temp: LaunchpadTemporaryDirectory
    let root: String
    let script: URL
    let argumentLog: URL
    let history = VPhoneLaunchpadCommandHistory()

    @MainActor
    init() throws {
        temp = try LaunchpadTemporaryDirectory(short: "lpe")
        let rootURL = temp.url.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = VPhoneLaunchpadMachineLocations.canonical(rootURL)
        argumentLog = temp.url.appendingPathComponent("arguments.log")
        script = temp.url.appendingPathComponent("vphone-cli")
        try """
        #!/bin/sh
        echo "$*" >> '\(argumentLog.path)'
        prev=""; root=""; out=""
        for a in "$@"; do
          [ "$prev" = "--library-root" ] && root="$a"
          [ "$prev" = "--out" ] && out="$a"
          prev="$a"
        done
        name="$3"
        case "$2" in
        list)
          if [ -e "$root/.list.json" ]; then cat "$root/.list.json"; else echo '[]'; fi
          exit 0 ;;
        esac
        if [ -e "$root/$name.busy" ]; then
          echo "Error: VM '$name' is busy: held by boot (pid 4242)" >&2
          exit 1
        fi
        case "$2" in
        export)
          trap 'echo "export $name got SIGINT"; exit 130' INT
          : > "$out"
          i=0
          while [ $i -lt 30 ]; do
            echo "chunk $i" >> "$out"
            i=$((i+1))
            [ -e "$root/.fast" ] && break
            sleep 0.1
          done
          echo "exported $name" ;;
        *) echo "$2 $name ok" ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func path(_ name: String) -> VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: root, name: name)
    }

    func makeMachines(_ names: [String]) throws {
        let bundles = try names.map { try LaunchpadReports.writeBundle(named: $0, in: URL(fileURLWithPath: root)) }
        try LaunchpadReports.listJSON(bundles).write(to: URL(fileURLWithPath: root).appendingPathComponent(".list.json"))
    }

    func touch(_ name: String) {
        FileManager.default.createFile(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path, contents: nil)
    }

    /// Recorded command lines other than `vm list`.
    var edits: [String] {
        ((try? String(contentsOf: argumentLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("vm list") }
    }

    @MainActor
    func library() async -> VPhoneLaunchpadMachineLibrary {
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: root, logsDirectory: temp.url.appendingPathComponent("Logs"),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: script, history: history))
        library.stopMonitoring()
        await library.refresh()
        return library
    }
}

// MARK: - Edits through the library

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EditLibraryTests {
    @Test func settingsRunOneConfigPerMachineAndAreRecorded() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        let library = await standIn.library()
        await library.configure([standIn.path("a"), standIn.path("b")], .init(cpu: 2, network: "none"))
        let root = standIn.root
        #expect(standIn.edits == [
            "vm config a --library-root \(root) --cpu 2 --network none",
            "vm config b --library-root \(root) --cpu 2 --network none",
        ])
        #expect(library.actionError == nil)
        #expect(library.activities.isEmpty)
        #expect(standIn.history.entries.map(\.text) == [
            "vphone-cli vm config a --library-root \(root) --cpu 2 --network none",
            "vphone-cli vm config b --library-root \(root) --cpu 2 --network none",
        ])
        #expect(standIn.history.entries.map(\.status) == [0, 0])
    }

    /// A machine whose bundle lock is held: Launchpad runs the command, the
    /// CLI refuses it, and the refusal is what the alert shows.
    @Test func aRefusalIsShownWithTheCLIOutput() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        standIn.touch("a.busy")
        let library = await standIn.library()

        await library.configure([standIn.path("a"), standIn.path("b")], .init(memoryMB: 4096))
        let error = try #require(library.actionError)
        #expect(error.message == "Unable to Save Settings for a")
        #expect(error.detail == "Error: VM 'a' is busy: held by boot (pid 4242)")
        #expect(standIn.history.entries.map(\.status) == [1, 0])

        library.actionError = nil
        await library.rename(standIn.path("a"), to: "a2")
        #expect(library.actionError?.message == "Unable to Rename a")
        #expect(library.selection == [standIn.path("a")])
        library.actionError = nil
        await library.delete([standIn.path("a")])
        #expect(library.actionError?.message == "Unable to Delete a")
        #expect(library.actionError?.detail?.contains("is busy") == true)
        #expect(library.activities.isEmpty)
    }

    @Test func renameSelectsTheNewNameAndCloneTheClone() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a"])
        let library = await standIn.library()
        await library.rename(standIn.path("a"), to: "a2")
        #expect(library.selection == [standIn.path("a2")])
        await library.clone(standIn.path("a2"), as: "a3")
        #expect(library.selection == [standIn.path("a3")])
        #expect(standIn.edits == [
            "vm rename a a2 --library-root \(standIn.root)",
            "vm clone a2 a3 --library-root \(standIn.root)",
        ])
        #expect(library.actionError == nil)
    }

    @Test func deleteRunsVMDeleteForEachMachineAndNothingElse() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        let library = await standIn.library()
        await library.delete([standIn.path("a"), standIn.path("b")])
        #expect(standIn.edits == [
            "vm delete a --force --library-root \(standIn.root)",
            "vm delete b --force --library-root \(standIn.root)",
        ])
        // The stand-in removes nothing; Launchpad removed nothing either.
        #expect(FileManager.default.fileExists(atPath: standIn.path("a").url.path))
        #expect(FileManager.default.fileExists(atPath: standIn.path("b").url.path))
    }

    @Test func importGoesIntoTheDefaultLibrary() async throws {
        let standIn = try LaunchpadEditStandIn()
        let library = await standIn.library()
        await library.importArchive(URL(fileURLWithPath: "/archives/m 1.tzst"))
        #expect(standIn.edits == ["vm import /archives/m 1.tzst --library-root \(standIn.root)"])
        #expect(standIn.history.entries.map(\.text) == ["vphone-cli vm import '/archives/m 1.tzst' --library-root \(standIn.root)"])
        #expect(library.globalActivity == nil)
    }

    @Test func aNameLaunchpadCannotPassRunsNothing() async throws {
        let standIn = try LaunchpadEditStandIn()
        let library = await standIn.library()
        await library.rename(standIn.path("-a"), to: "b")
        #expect(library.actionError?.message == "Unable to Rename -a")
        #expect(standIn.edits.isEmpty)
        #expect(standIn.history.entries.isEmpty)
    }

    @Test func exportsRunOneAtATime() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        let library = await standIn.library()
        let out = standIn.temp.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let items = [(standIn.path("a"), out.appendingPathComponent("a.tzst")),
                     (standIn.path("b"), out.appendingPathComponent("b.tzst"))]
        let export = Task { await library.export(items, densest: false, includeIPSW: false, replacing: false) }

        #expect(await eventually { library.isExporting(standIn.path("a")) })
        #expect(library.activity(of: standIn.path("a")) == "Exporting…")
        #expect(library.exports[standIn.path("b")]?.isWaiting == true)
        #expect(library.activity(of: standIn.path("b")) == "Waiting to export…")
        #expect(!library.canEdit(standIn.path("a")))
        #expect(!library.canEdit(standIn.path("b")))
        standIn.touch(".fast")
        await export.value

        #expect(library.exports.isEmpty)
        #expect(standIn.edits == [
            "vm export a --out \(out.path)/a.tzst --library-root \(standIn.root)",
            "vm export b --out \(out.path)/b.tzst --library-root \(standIn.root)",
        ])
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("a.tzst").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("b.tzst").path))
        #expect(library.canEdit(standIn.path("a")))
    }

    @Test func cancellingAWaitingExportTakesItOutOfTheQueue() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        let library = await standIn.library()
        let out = standIn.temp.url
        let export = Task {
            await library.export([(standIn.path("a"), out.appendingPathComponent("a.tzst")),
                                  (standIn.path("b"), out.appendingPathComponent("b.tzst"))],
                                 densest: true, includeIPSW: true, replacing: false)
        }
        #expect(await eventually { library.isExporting(standIn.path("a")) })
        library.cancelExport(standIn.path("b"))
        #expect(library.exports[standIn.path("b")] == nil)
        standIn.touch(".fast")
        await export.value
        #expect(standIn.edits == ["vm export a --out \(out.path)/a.tzst --library-root \(standIn.root) --max --include-ipsw"])
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("b.tzst").path))
    }

    /// Cancel sends SIGINT to the `vm export` child and removes the partial
    /// archive that export created; it is not reported as an error.
    @Test func cancellingARunningExportRemovesOnlyTheFileItCreated() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a"])
        let library = await standIn.library()
        let file = standIn.temp.url.appendingPathComponent("a.tzst")
        let export = Task { await library.export([(standIn.path("a"), file)], densest: false, includeIPSW: false, replacing: true) }
        #expect(await eventually { ((try? Data(contentsOf: file))?.count ?? 0) > 0 })
        library.cancelExport(standIn.path("a"))
        await export.value

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(library.actionError == nil)
        #expect(library.exports.isEmpty)
        // Ended by its SIGINT trap (130), not by finishing its 3 s of
        // writes (0). The trap can only be set when SIGINT is not ignored on
        // entry, which the test host's own disposition would cause.
        #expect(standIn.history.entries.last?.status == 130)
    }

    @Test func cancellingAnExportOverAnExistingFileLeavesThatFile() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a"])
        let library = await standIn.library()
        let file = standIn.temp.url.appendingPathComponent("a.tzst")
        FileManager.default.createFile(atPath: file.path, contents: Data("earlier archive\n".utf8))
        let export = Task { await library.export([(standIn.path("a"), file)], densest: false, includeIPSW: false, replacing: true) }
        #expect(await eventually { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasPrefix("chunk") })
        library.cancelExport(standIn.path("a"))
        await export.value
        // The save panel asked before replacing it; the export truncated it,
        // but Launchpad does not remove a path that held a file before.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFolderExportDoesNotReplaceAnExistingFile() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a", "b"])
        standIn.touch(".fast")
        let library = await standIn.library()
        let out = standIn.temp.url
        let existing = out.appendingPathComponent("a.tzst")
        FileManager.default.createFile(atPath: existing.path, contents: Data("keep".utf8))
        await library.export([(standIn.path("a"), existing), (standIn.path("b"), out.appendingPathComponent("b.tzst"))],
                             densest: false, includeIPSW: false, replacing: false)
        #expect(library.actionError?.message == "Unable to Export a")
        #expect(library.actionError?.detail == "\(existing.path) already exists.")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        #expect(standIn.edits == ["vm export b --out \(out.path)/b.tzst --library-root \(standIn.root)"])
    }

    @Test func historyRecordsEveryEditButNotTheListing() async throws {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["a"])
        standIn.touch(".fast")
        let library = await standIn.library()
        await library.refresh()
        await library.configure([standIn.path("a")], .init(cpu: 3))
        await library.export([(standIn.path("a"), standIn.temp.url.appendingPathComponent("a.tzst"))],
                             densest: false, includeIPSW: false, replacing: false)
        await library.clone(standIn.path("a"), as: "b")
        #expect(standIn.history.entries.map { String($0.text.split(separator: " ").prefix(3).joined(separator: " ")) }
            == ["vphone-cli vm config", "vphone-cli vm export", "vphone-cli vm clone"])
        #expect(standIn.history.entries.allSatisfy { $0.status == 0 })
    }
}
