import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - Locations

struct LocationTests {
    @Test func defaultRootIsTheCLIDefaultCanonical() {
        #expect(VPhoneLaunchpadMachineLocations.defaultRoot
            == VPhoneLaunchpadMachineLocations.canonical(VPhoneLibrary.defaultRoot()))
    }

    @Test func canonicalResolvesSymbolicLinks() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let real = temp.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = temp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(VPhoneLaunchpadMachineLocations.canonical(link) == VPhoneLaunchpadMachineLocations.canonical(real))
        #expect(VPhoneLaunchpadMachineLocations.canonical(real).hasPrefix("/private/"))
        // A missing folder keeps its standardized spelling.
        #expect(VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: "/launchpad-missing/a/../b"))
            == "/launchpad-missing/b")
    }

    @Test func addedRootsAreAbsoluteCanonicalUniqueAndNotTheDefault() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let real = temp.url.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = temp.url.appendingPathComponent("second-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let roots = VPhoneLaunchpadMachineLocations.addedRoots(
            from: [real.path, "relative/path", link.path, "/default-root", real.path],
            defaultRoot: "/default-root"
        )
        #expect(roots == [VPhoneLaunchpadMachineLocations.canonical(real)])
    }

    @Test func consoleLogsAreSeparatedPerLibrary() {
        let logs = URL(fileURLWithPath: "/logs", isDirectory: true)
        let inDefault = VPhoneLaunchpadMachinePath(libraryRoot: "/lib/default", name: "phone")
        let inOther = VPhoneLaunchpadMachinePath(libraryRoot: "/lib/other", name: "phone")
        let inThird = VPhoneLaunchpadMachinePath(libraryRoot: "/lib/third", name: "phone")
        let a = VPhoneLaunchpadMachineLocations.consoleLog(inDefault, defaultRoot: "/lib/default", logsDirectory: logs)
        let b = VPhoneLaunchpadMachineLocations.consoleLog(inOther, defaultRoot: "/lib/default", logsDirectory: logs)
        let c = VPhoneLaunchpadMachineLocations.consoleLog(inThird, defaultRoot: "/lib/default", logsDirectory: logs)
        #expect(a.path == "/logs/phone.log")
        #expect(b.lastPathComponent == "phone-\(VPhoneLaunchpadMachineLocations.digest("/lib/other")).log")
        #expect(Set([a, b, c]).count == 3)
        #expect(VPhoneLaunchpadMachineLocations.digest("/lib/other").count == 8)
        #expect(VPhoneLaunchpadMachineLocations.consoleLog(inOther, suffix: "-create", defaultRoot: "/lib/default", logsDirectory: logs)
            .lastPathComponent.hasSuffix("-create.log"))
    }

    @Test func localIdentityIsSeparateFromUpstream() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(VPhoneLaunchpadIdentity.bundleIdentifier == "com.vphone.cli.launchpad")
        #expect(VPhoneLaunchpadIdentity.logsDirectory(home: home).path == "/Users/someone/Library/Logs/vphone-cli-launchpad")
        #expect(VPhoneLaunchpadIdentity.supportDirectory(home: home).path
            == "/Users/someone/Library/Application Support/vphone-cli-launchpad")
    }
}

// MARK: - Library

/// `vm list` through a stand-in `vphone-cli`: a shell script that records its
/// arguments, prints a warning on stderr, and prints `<root>/.list.json`.
@MainActor
struct LibraryTests {
    let temp: LaunchpadTemporaryDirectory
    let defaults = InMemoryDefaults()
    let script: URL
    let argumentLog: URL

    init() throws {
        temp = try LaunchpadTemporaryDirectory()
        argumentLog = temp.url.appendingPathComponent("arguments.log")
        script = temp.url.appendingPathComponent("vphone-cli")
        try """
        #!/bin/sh
        echo "$*" >> '\(argumentLog.path)'
        echo "warning: skipping broken: config.plist unreadable" >&2
        if [ -e "$5/.fail" ]; then echo "error: cannot list $5" >&2; exit 3; fi
        if [ -e "$5/.list.json" ]; then cat "$5/.list.json"; else echo '[]'; fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func makeRoot(_ name: String, machines: [String]) throws -> String {
        let root = temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundles = try machines.map { try LaunchpadReports.writeBundle(named: $0, in: root) }
        try LaunchpadReports.listJSON(bundles).write(to: root.appendingPathComponent(".list.json"))
        return VPhoneLaunchpadMachineLocations.canonical(root)
    }

    private func library(defaultRoot: String) -> VPhoneLaunchpadMachineLibrary {
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: defaults, libraryRoot: defaultRoot,
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        // Sets the command line without leaving a polling task behind.
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: script, history: VPhoneLaunchpadCommandHistory()))
        library.stopMonitoring()
        return library
    }

    @Test func listsDefaultAndAddedLibraries() async throws {
        let first = try makeRoot("first", machines: ["one", "two"])
        let second = try makeRoot("second", machines: ["three"])
        defaults.set([second], forKey: VPhoneLaunchpadMachineLibrary.addedRootsKey)

        let library = library(defaultRoot: first)
        #expect(library.roots == [first, second])
        await library.refresh()

        #expect(library.hasListed)
        #expect(library.listError == nil)
        #expect(library.machines.map(\.name) == ["one", "two", "three"])
        #expect(library.machines.map(\.libraryRoot) == [first, first, second])
        #expect(library.spansLibraries)
        #expect(library.selection == [library.machines[0].id])
        #expect(library.machines.allSatisfy { library.state(of: $0.path) == .stopped })
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8).split(separator: "\n")
        #expect(arguments == ["vm list --json --library-root \(first)", "vm list --json --library-root \(second)"])
    }

    @Test func missingAddedLibraryIsSkippedAndFailureKeepsLastListing() async throws {
        let first = try makeRoot("first", machines: ["one"])
        defaults.set([temp.url.appendingPathComponent("unmounted").path], forKey: VPhoneLaunchpadMachineLibrary.addedRootsKey)
        let library = library(defaultRoot: first)
        await library.refresh()
        #expect(library.machines.map(\.name) == ["one"])
        #expect(try String(contentsOf: argumentLog, encoding: .utf8).split(separator: "\n").count == 1)

        FileManager.default.createFile(atPath: URL(fileURLWithPath: first).appendingPathComponent(".fail").path, contents: nil)
        await library.refresh()
        #expect(library.machines.map(\.name) == ["one"])
        #expect(library.listError?.contains("error: cannot list") == true)
    }

    @Test func addedLocationPersistsInInjectedDefaults() throws {
        let first = try makeRoot("first", machines: [])
        let second = try makeRoot("second", machines: [])
        let library = library(defaultRoot: first)
        library.addLocation(first)
        library.addLocation(second)
        library.addLocation(temp.url.appendingPathComponent("second").path)
        #expect(library.addedRoots == [second])
        #expect(defaults.stringArray(forKey: VPhoneLaunchpadMachineLibrary.addedRootsKey) == [second])
        #expect(UserDefaults.standard.stringArray(forKey: VPhoneLaunchpadMachineLibrary.addedRootsKey) == nil)
        #expect(self.library(defaultRoot: first).roots == [first, second])
    }

    @Test func cancellingARunInterruptsOnlyItsChild() async throws {
        let sleeper = temp.url.appendingPathComponent("sleeper")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleeper.path)
        let history = VPhoneLaunchpadCommandHistory()
        let commandLine = VPhoneLaunchpadCommandLine(executable: sleeper, history: history)
        let started = Date()
        let task = Task { try await commandLine.run(["vm", "list"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        #expect(result.status == SIGINT)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(history.entries.map(\.text) == ["vphone-cli vm list"])
        #expect(history.entries.first?.status == SIGINT)
    }
}

/// Injected defaults kept in memory, so tests write no preference file.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    override func stringArray(forKey key: String) -> [String]? {
        object(forKey: key) as? [String]
    }
}
