import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - Stand-in vphone-cli

/// A shell script in place of `vphone-cli`, for `vm list`, `vm launch` and
/// `vm stop`. Every call appends its arguments to `arguments.log`.
///
/// - `vm launch <name>` prints a serial line every 0.1 s until it is
///   interrupted (prints `got SIGINT`, exits 130), until `<root>/<name>.exit`
///   exists (exits 7), and prints a coloured panic line once
///   `<root>/<name>.panic` exists.
/// - `vm stop <name>` waits 0.3 s, records whether the machine's console log
///   already shows `got SIGINT`, prints `<name>: stopped` and exits 0, or 1
///   when `<root>/<name>.stopfail` exists. It signals nothing.
struct LaunchpadStandIn {
    let temp: LaunchpadTemporaryDirectory
    let root: String
    let logs: URL
    let script: URL
    let argumentLog: URL

    init() throws {
        temp = try LaunchpadTemporaryDirectory("launchpad-launch")
        let rootURL = temp.url.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = VPhoneLaunchpadMachineLocations.canonical(rootURL)
        logs = temp.url.appendingPathComponent("Logs", isDirectory: true)
        argumentLog = temp.url.appendingPathComponent("arguments.log")
        script = temp.url.appendingPathComponent("vphone-cli")
        try """
        #!/bin/sh
        echo "$*" >> '\(argumentLog.path)'
        name="$3"; root="$5"
        case "$2" in
        list)
          if [ -e "$root/.list.json" ]; then cat "$root/.list.json"; else echo '[]'; fi ;;
        launch)
          trap 'echo "launch $name got SIGINT"; exit 130' INT
          echo "launch $name started"
          i=0
          while :; do
            echo "serial $name $i"
            i=$((i+1))
            if [ -e "$root/$name.panic" ]; then
              rm -f "$root/$name.panic"
              printf '\\033[31mpanic(cpu 0 caller 0xfffffff007): stand-in\\033[0m\\n'
            fi
            if [ -e "$root/$name.exit" ]; then echo "launch $name exiting"; exit 7; fi
            sleep 0.1
          done ;;
        stop)
          sleep 0.3
          if grep -q "got SIGINT" '\(logs.path)'/"$name.log" 2>/dev/null; then
            echo "stop $name saw SIGINT" >> '\(argumentLog.path)'
          else
            echo "stop $name saw no SIGINT" >> '\(argumentLog.path)'
          fi
          if [ -e "$root/$name.stopfail" ]; then echo "error: $name: stop failed" >&2; exit 1; fi
          echo "$name: stopped" ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func path(_ name: String) -> VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: root, name: name)
    }

    /// Bundles and the `vm list` answer for `names`.
    func makeMachines(_ names: [String]) throws {
        let bundles = try names.map { try LaunchpadReports.writeBundle(named: $0, in: URL(fileURLWithPath: root)) }
        try LaunchpadReports.listJSON(bundles).write(to: URL(fileURLWithPath: root).appendingPathComponent(".list.json"))
    }

    func touch(_ name: String) {
        FileManager.default.createFile(atPath: URL(fileURLWithPath: root).appendingPathComponent(name).path, contents: nil)
    }

    func log(_ name: String) -> String {
        (try? String(contentsOf: logs.appendingPathComponent("\(name).log"), encoding: .utf8)) ?? ""
    }

    var arguments: [String] {
        ((try? String(contentsOf: argumentLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @MainActor
    func library() async -> VPhoneLaunchpadMachineLibrary {
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: root, logsDirectory: logs,
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: script, history: VPhoneLaunchpadCommandHistory()))
        library.stopMonitoring()
        await library.refresh()
        return library
    }
}

/// Polls `condition` every 50 ms for up to `seconds`.
@MainActor
func eventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

// MARK: - Detached child

@Suite(.timeLimit(.minutes(1)))
struct DetachedChildTests {
    @Test func runsInItsOwnSessionWithNullStdinAndOnlyTheLogOpen() async throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-detached")
        let script = temp.url.appendingPathComponent("child")
        let log = temp.url.appendingPathComponent("Logs/child.log")
        try """
        #!/bin/sh
        if read line; then echo "stdin had data"; else echo "stdin at end of file"; fi
        if [ -e /dev/fd/250 ]; then echo "fd 250 inherited"; else echo "fd 250 not inherited"; fi
        echo "to stderr" >&2
        sleep 0.5
        exit 7
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // A descriptor without close-on-exec, as Launchpad may hold for a
        // window server or log; the child must not inherit it.
        let descriptor = open("/dev/null", O_RDONLY)
        try #require(fcntl(250, F_GETFD) == -1, "descriptor 250 is in use")
        #expect(dup2(descriptor, 250) == 250)
        defer {
            close(250)
            close(descriptor)
        }

        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(executable: script, arguments: [], logFile: log) { lines.append($0) }
        let pid = child.processIdentifier
        #expect(child.isDetached)
        #expect(getsid(pid) == pid)
        #expect(getpgid(pid) == pid)
        #expect(getsid(pid) != getsid(0))

        let childStatus = await child.wait()

        #expect(childStatus == 7)
        #expect(!child.isRunning)
        let expected = ["stdin at end of file", "fd 250 not inherited", "to stderr"]
        #expect(lines.all == expected)
        #expect(try String(contentsOf: log, encoding: .utf8) == expected.joined(separator: "\n") + "\n")
        // Exited and reaped: nothing is sent, even though the PID may be reused.
        #expect(child.interrupt() == false)
    }

    @Test func startingReplacesTheLogWithANewFile() async throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-detached")
        let log = temp.url.appendingPathComponent("child.log")
        try "previous run\n".write(to: log, atomically: true, encoding: .utf8)
        let before = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int)
        let child = try VPhoneLaunchpadChildProcess(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["this run"], logFile: log) { _ in }
        let childStatus2 = await child.wait()
        #expect(childStatus2 == 0)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int)
        #expect(after != before)
        #expect(try String(contentsOf: log, encoding: .utf8) == "this run\n")
    }

    /// The test host already ignores SIGINT (swiftpm-testing-helper); an
    /// ignored signal survives exec, and a shell cannot trap a signal ignored
    /// on entry. The child must start with the default disposition anyway.
    @Test func interruptReachesTheRunningChildEvenWhenTheParentIgnoresSIGINT() async throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-detached")
        let script = temp.url.appendingPathComponent("child")
        try "#!/bin/sh\ntrap 'echo interrupted; exit 130' INT\necho ready\nwhile :; do sleep 0.1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let previous = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previous) }
        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(
            executable: script, arguments: [], logFile: temp.url.appendingPathComponent("child.log")) { lines.append($0) }
        // The trap is set once the child prints.
        for _ in 0 ..< 200 where lines.all.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(child.interrupt())
        let status = await child.wait()
        #expect(status == 130)
        #expect(lines.all == ["ready", "interrupted"])
        #expect(child.interrupt() == false)
    }

    @Test func exitCodeMatchesProcessTerminationStatus() {
        #expect(VPhoneLaunchpadChildProcess.exitCode(7 << 8) == 7)
        #expect(VPhoneLaunchpadChildProcess.exitCode(SIGINT) == SIGINT)
        #expect(VPhoneLaunchpadChildProcess.exitCode(SIGKILL | 0x80) == SIGKILL)
    }
}

/// Lines collected from a reader thread.
final class LaunchpadLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var all: [String] {
        lock.withLock { storage }
    }
}

// MARK: - Start and stop

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LaunchTests {
    @Test func startRunsVMLaunchDetachedAndAppendsTheExitLine() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        #expect(library.canStart(alpha))

        library.start(alpha, headless: true)
        let child = try #require(library.launchedProcess(alpha))
        #expect(child.isDetached)
        #expect(library.state(of: alpha) == .running(instanceID: nil))
        #expect(library.startedAt[alpha] != nil)
        #expect(!library.canStart(alpha))
        #expect(library.canStop(alpha))
        #expect(library.consoleLog(alpha) == standIn.logs.appendingPathComponent("alpha.log"))

        #expect(await eventually { standIn.log("alpha").contains("serial alpha 3") })
        #expect(standIn.arguments.contains("vm launch alpha --library-root \(standIn.root) --headless"))
        standIn.touch("alpha.exit")
        let childStatus3 = await child.wait()
        #expect(childStatus3 == 7)
        #expect(await eventually { library.launchedProcess(alpha) == nil })
        #expect(library.startedAt[alpha] == nil)
        #expect(library.state(of: alpha) == .stopped)
        let lines = standIn.log("alpha").split(separator: "\n").map(String.init)
        #expect(lines.first == "launch alpha started")
        #expect(lines.suffix(2) == ["launch alpha exiting", "vm launch exited with status 7"])
        // Serial lines arrive in order, appended by the child.
        let serial = lines.filter { $0.hasPrefix("serial alpha ") }.compactMap { Int($0.split(separator: " ").last!) }
        #expect(serial == Array(0 ..< serial.count))
    }

    @Test func twoMachinesWriteSeparateLogs() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha", "beta"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        let beta = standIn.path("beta")
        library.start(alpha)
        library.start(beta)
        #expect(await eventually { standIn.log("alpha").contains("serial alpha 5") && standIn.log("beta").contains("serial beta 5") })
        #expect(!standIn.log("alpha").contains("beta"))
        #expect(!standIn.log("beta").contains("alpha"))
        let a = try #require(library.launchedProcess(alpha))
        let b = try #require(library.launchedProcess(beta))
        #expect(a.processIdentifier != b.processIdentifier)
        a.interrupt()
        b.interrupt()
        let aStatus4 = await a.wait()
        #expect(aStatus4 == 130)
        let bStatus5 = await b.wait()
        #expect(bStatus5 == 130)
    }

    @Test func stopRunsVMStopThenInterruptsOnlyItsOwnChild() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha", "beta", "outside"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        let beta = standIn.path("beta")
        let outside = standIn.path("outside")
        library.start(alpha)
        library.start(beta)
        let a = try #require(library.launchedProcess(alpha))
        let b = try #require(library.launchedProcess(beta))

        // A machine some other program started: Launchpad holds no child for it.
        let outsideLog = standIn.temp.url.appendingPathComponent("outside-own.log")
        FileManager.default.createFile(atPath: outsideLog.path, contents: nil)
        let external = Process()
        external.executableURL = standIn.script
        external.arguments = ["vm", "launch", "outside", "--library-root", standIn.root]
        external.standardOutput = try FileHandle(forWritingTo: outsideLog)
        try external.run()
        defer {
            if external.isRunning {
                external.terminate()
            }
        }
        #expect(await eventually { standIn.log("alpha").contains("serial alpha 2") })

        await library.stop(alpha)
        let aStatus6 = await a.wait()
        #expect(aStatus6 == 130)
        #expect(standIn.arguments.contains("vm stop alpha --library-root \(standIn.root)"))
        // vm stop ran to completion before the SIGINT.
        #expect(standIn.arguments.contains("stop alpha saw no SIGINT"))
        #expect(standIn.log("alpha").contains("launch alpha got SIGINT"))
        #expect(library.activities[alpha] == nil)
        #expect(library.actionError == nil)

        // The other child and the outside process received nothing.
        #expect(b.isRunning)
        #expect(!standIn.log("beta").contains("got SIGINT"))
        await library.stop(outside)
        #expect(standIn.arguments.contains("vm stop outside --library-root \(standIn.root)"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(external.isRunning)
        #expect(!(try String(contentsOf: outsideLog, encoding: .utf8)).contains("got SIGINT"))

        b.interrupt()
        let bStatus7 = await b.wait()
        #expect(bStatus7 == 130)
    }

    @Test func failedStopIsReportedAndOwnChildStillInterrupted() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        standIn.touch("alpha.stopfail")
        library.start(alpha)
        let a = try #require(library.launchedProcess(alpha))
        #expect(await eventually { standIn.log("alpha").contains("serial alpha 0") })
        await library.stop(alpha)
        #expect(library.actionError?.detail?.contains("error: alpha: stop failed") == true)
        let aStatus8 = await a.wait()
        #expect(aStatus8 == 130)
    }

    @Test func panicLineMarksTheMachineUntilItStartsAgain() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        library.start(alpha)
        #expect(await eventually { standIn.log("alpha").contains("serial alpha 1") })
        #expect(!library.panicked.contains(alpha))
        standIn.touch("alpha.panic")
        #expect(await eventually { library.panicked.contains(alpha) })
        let a = try #require(library.launchedProcess(alpha))
        a.interrupt()
        let aStatus9 = await a.wait()
        #expect(aStatus9 == 130)
        #expect(await eventually { library.canStart(alpha) })
        library.start(alpha)
        #expect(!library.panicked.contains(alpha))
        let again = try #require(library.launchedProcess(alpha))
        // The new run replaced the log; its trap is set once it prints.
        #expect(await eventually { standIn.log("alpha").hasPrefix("launch alpha started") })
        #expect(!standIn.log("alpha").contains("panic"))
        again.interrupt()
        let againStatus10 = await again.wait()
        #expect(againStatus10 == 130)
    }
}

// MARK: - Parent exit

/// The arguments that re-run this test bundle in a new
/// `swiftpm-testing-helper` process limited to `filter`, or nil when the
/// tests run under another host (for example Xcode's xctest).
func testBundleRerun(filter: String) -> (helper: URL, arguments: [String])? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--test-bundle-path"), index + 1 < arguments.count,
          arguments[0].hasSuffix("swiftpm-testing-helper")
    else { return nil }
    let bundle = arguments[index + 1]
    return (URL(fileURLWithPath: arguments[0]),
            ["--test-bundle-path", bundle, "--filter", filter, bundle, "--testing-library", "swift-testing"])
}

/// What `LaunchParentRole` starts, written by the test that runs it (or by
/// the B2 smoke script). Read from the file `VPHONE_LAUNCHPAD_PARENT_ROLE`
/// names.
struct LaunchParentRoleConfiguration: Codable {
    struct Machine: Codable {
        let root: String
        let name: String
    }

    static let environmentKey = "VPHONE_LAUNCHPAD_PARENT_ROLE"

    let executable: String
    let defaultRoot: String
    let logs: String
    let machines: [Machine]
    let pidFile: String
    /// Text every machine's console log shows before the process exits.
    let ready: String

    static var current: LaunchParentRoleConfiguration? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return try? JSONDecoder().decode(LaunchParentRoleConfiguration.self, from: data)
    }
}

/// Plays Launchpad in a separate, short-lived process: starts the machines
/// through `VPhoneLaunchpadMachineLibrary.start` (the method the Start
/// button calls), records the child PIDs, waits for their output and
/// returns, so the process exits with the children still running. Enabled
/// only in that process.
@MainActor
@Suite(.enabled(if: LaunchParentRoleConfiguration.current != nil), .timeLimit(.minutes(1)))
struct LaunchParentRole {
    @Test func startMachinesThenExit() async throws {
        let configuration = try #require(LaunchParentRoleConfiguration.current)
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: configuration.defaultRoot,
            logsDirectory: URL(fileURLWithPath: configuration.logs, isDirectory: true),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        for root in configuration.machines.map(\.root) where root != configuration.defaultRoot {
            library.addLocation(root)
        }
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(
            executable: URL(fileURLWithPath: configuration.executable), history: VPhoneLaunchpadCommandHistory()))
        library.stopMonitoring()
        await library.refresh()
        var pids: [String] = []
        for machine in configuration.machines {
            let path = VPhoneLaunchpadMachinePath(libraryRoot: machine.root, name: machine.name)
            #expect(library.canStart(path))
            library.start(path)
            pids.append(String(try #require(library.launchedProcess(path)).processIdentifier))
        }
        try pids.joined(separator: "\n").write(toFile: configuration.pidFile, atomically: true, encoding: .utf8)
        for machine in configuration.machines {
            let log = library.consoleLog(VPhoneLaunchpadMachinePath(libraryRoot: machine.root, name: machine.name))
            #expect(await eventually(20) {
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(configuration.ready)
            })
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ParentExitTests {
    /// Runs `LaunchParentRole` in a new test process, which exits after
    /// starting two machines. The children keep running in their own
    /// sessions, re-parented to launchd, and keep writing their logs; the
    /// exited process's pipe was not inherited, or reading it to the end
    /// would wait for the children.
    @Test(.enabled(if: testBundleRerun(filter: "LaunchParentRole") != nil))
    func childrenOutliveTheProcessThatStartedThem() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha", "beta"])
        let pidFile = standIn.temp.url.appendingPathComponent("children.pid")
        let configurationFile = standIn.temp.url.appendingPathComponent("parent-role.json")
        try JSONEncoder().encode(LaunchParentRoleConfiguration(
            executable: standIn.script.path, defaultRoot: standIn.root, logs: standIn.logs.path,
            machines: [.init(root: standIn.root, name: "alpha"), .init(root: standIn.root, name: "beta")],
            pidFile: pidFile.path, ready: "serial"
        )).write(to: configurationFile)

        let rerun = try #require(testBundleRerun(filter: "LaunchParentRole"))
        let parent = Process()
        parent.executableURL = rerun.helper
        parent.arguments = rerun.arguments
        var environment = ProcessInfo.processInfo.environment
        environment[LaunchParentRoleConfiguration.environmentKey] = configurationFile.path
        parent.environment = environment
        let pipe = Pipe()
        parent.standardOutput = pipe
        parent.standardError = pipe
        try parent.run()
        let output = await Task.detached { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }.value
        parent.waitUntilExit()
        #expect(parent.terminationStatus == 0, "\(output)")
        #expect(output.contains("startMachinesThenExit() passed"), "\(output)")

        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").compactMap { pid_t($0) }
        #expect(pids.count == 2)
        defer {
            // Cleanup: the stand-ins exit by themselves once told to.
            standIn.touch("alpha.exit")
            standIn.touch("beta.exit")
        }
        for pid in pids {
            #expect(isAlive(pid))
            #expect(getsid(pid) == pid)
            let ppid = try LaunchpadProcess.run("/bin/ps", ["-o", "ppid=", "-p", String(pid)]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ppid == "1")
        }
        let before = (standIn.log("alpha").count, standIn.log("beta").count)
        try await Task.sleep(for: .milliseconds(600))
        #expect(standIn.log("alpha").count > before.0)
        #expect(standIn.log("beta").count > before.1)
        #expect(!standIn.log("alpha").contains("beta"))
        #expect(!standIn.log("beta").contains("alpha"))

        standIn.touch("alpha.exit")
        standIn.touch("beta.exit")
        #expect(await eventually { pids.allSatisfy { !isAlive($0) } })
        // Nobody was left to add the exit line.
        #expect(!standIn.log("alpha").contains("vm launch exited"))
        #expect(standIn.log("alpha").hasSuffix("launch alpha exiting\n"))
    }
}

// MARK: - Console log

struct ConsoleLogTests {
    @Test func panicLines() {
        for line in [
            "panic(cpu 0 caller 0xfffffff0071b2c3c): \"stand-in\"",
            "Kernel panic - not syncing",
            "Please go to https://panic.apple.com to report this panic",
            "stackshot succeeded",
            "PANIC",
        ] {
            #expect(VPhoneLaunchpadConsoleLog.isPanic(line), "\(line)")
        }
        for line in ["serial alpha 3", "vm launch exited with status 0", "booting kernel", "ppanic"] {
            #expect(!VPhoneLaunchpadConsoleLog.isPanic(line), "\(line)")
        }
    }

    @Test func exitLineIsAppendedOnItsOwnLine() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-console")
        let log = temp.url.appendingPathComponent("m.log")
        try "partial".write(to: log, atomically: true, encoding: .utf8)
        VPhoneLaunchpadConsoleLog.append(VPhoneLaunchpadConsoleLog.exitLine(status: 130), to: log)
        #expect(try String(contentsOf: log, encoding: .utf8) == "partial\nvm launch exited with status 130\n")
        // A missing log is not created.
        let missing = temp.url.appendingPathComponent("missing.log")
        VPhoneLaunchpadConsoleLog.append("x", to: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}

// MARK: - Console log rotation

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConsoleLogRotationTests {
    /// Starts `name` through the library, waits for its first serial line,
    /// then lets the stand-in exit and waits for the exit line.
    @MainActor
    func startAndFinish(_ standIn: LaunchpadStandIn, _ library: VPhoneLaunchpadMachineLibrary, _ name: String) async throws {
        let machine = standIn.path(name)
        library.start(machine)
        let child = try #require(library.launchedProcess(machine))
        #expect(await eventually { standIn.log(name).contains("serial \(name) 1") })
        standIn.touch("\(name).exit")
        _ = await child.wait()
        #expect(await eventually { standIn.log(name).contains("vm launch exited with status 7") })
        try FileManager.default.removeItem(atPath: URL(fileURLWithPath: standIn.root).appendingPathComponent("\(name).exit").path)
        #expect(await eventually { library.launchedProcess(machine) == nil })
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func previousLogNameKeepsTheStem() {
        let logs = URL(fileURLWithPath: "/tmp/Logs", isDirectory: true)
        #expect(VPhoneLaunchpadConsoleLog.previousLog(logs.appendingPathComponent("alpha.log")).lastPathComponent == "alpha.1.log")
        #expect(VPhoneLaunchpadConsoleLog.previousLog(logs.appendingPathComponent("a.b-1a2b3c4d.log")).lastPathComponent
            == "a.b-1a2b3c4d.1.log")
    }

    @Test func firstStartHasNoPreviousLog() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        let library = await standIn.library()
        let log = library.consoleLog(standIn.path("alpha"))
        #expect(VPhoneLaunchpadConsoleLog.rotate(log, in: standIn.logs) == .noPreviousLog)
        try await startAndFinish(standIn, library, "alpha")
        #expect(!FileManager.default.fileExists(atPath: VPhoneLaunchpadConsoleLog.previousLog(log).path))
        #expect(standIn.log("alpha").hasPrefix("launch alpha started\n"))
    }

    @Test func startKeepsThePreviousRunAsDotOne() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        try await startAndFinish(standIn, library, "alpha")
        let first = standIn.log("alpha")
        try await startAndFinish(standIn, library, "alpha")
        // The console and Show Console Log still use the current log.
        #expect(library.consoleLog(alpha) == standIn.logs.appendingPathComponent("alpha.log"))
        #expect(read(standIn.logs.appendingPathComponent("alpha.1.log")) == first)
        #expect(standIn.log("alpha").hasPrefix("launch alpha started\n"))
        #expect(standIn.log("alpha").components(separatedBy: "launch alpha started").count == 2)
    }

    @Test func existingDotOneIsReplaced() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        try FileManager.default.createDirectory(at: standIn.logs, withIntermediateDirectories: true)
        try "older run\n".write(to: standIn.logs.appendingPathComponent("alpha.1.log"), atomically: true, encoding: .utf8)
        try "previous run\n".write(to: standIn.logs.appendingPathComponent("alpha.log"), atomically: true, encoding: .utf8)
        let library = await standIn.library()
        try await startAndFinish(standIn, library, "alpha")
        #expect(read(standIn.logs.appendingPathComponent("alpha.1.log")) == "previous run\n")
        #expect(!standIn.log("alpha").contains("previous run"))
        let names = try FileManager.default.contentsOfDirectory(atPath: standIn.logs.path).filter { $0.hasPrefix("alpha") }
        #expect(names.sorted() == ["alpha.1.log", "alpha.log"])
    }

    @Test func symbolicLinkLogIsNotRotatedAndTheStartGoesOn() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha"])
        try FileManager.default.createDirectory(at: standIn.logs, withIntermediateDirectories: true)
        let target = standIn.temp.url.appendingPathComponent("elsewhere.txt")
        try "not a log\n".write(to: target, atomically: true, encoding: .utf8)
        let log = standIn.logs.appendingPathComponent("alpha.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        #expect(VPhoneLaunchpadConsoleLog.rotate(log, in: standIn.logs) == .failed("alpha.log is a symbolic link"))

        let library = await standIn.library()
        try await startAndFinish(standIn, library, "alpha")
        #expect(!FileManager.default.fileExists(atPath: standIn.logs.appendingPathComponent("alpha.1.log").path))
        #expect(read(target) == "not a log\n")
        let type = try FileManager.default.attributesOfItem(atPath: log.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        let lines = standIn.log("alpha").split(separator: "\n").map(String.init)
        #expect(lines.first == "Launchpad did not keep the previous console log: alpha.log is a symbolic link")
        #expect(lines.dropFirst().first == "launch alpha started")
    }

    @Test func startDoesNotReplaceTheLogOfAMachineNamedDotOne() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha", "alpha.1"])
        try FileManager.default.createDirectory(at: standIn.logs, withIntermediateDirectories: true)
        try "alpha run\n".write(to: standIn.logs.appendingPathComponent("alpha.log"), atomically: true, encoding: .utf8)
        try "alpha.1 run\n".write(to: standIn.logs.appendingPathComponent("alpha.1.log"), atomically: true, encoding: .utf8)
        let library = await standIn.library()
        try await startAndFinish(standIn, library, "alpha")
        #expect(standIn.log("alpha.1") == "alpha.1 run\n")
        #expect(standIn.log("alpha").hasPrefix(
            "Launchpad did not keep the previous console log: alpha.1.log is the console log of another machine\n"))
    }

    @Test func rotationStaysInTheLogsDirectory() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-rotate")
        let logs = temp.url.appendingPathComponent("Logs", isDirectory: true)
        let real = temp.url.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "run\n".write(to: real.appendingPathComponent("alpha.log"), atomically: true, encoding: .utf8)
        // A logs directory that is a symbolic link is not used.
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: real)
        let rotation = VPhoneLaunchpadConsoleLog.rotate(logs.appendingPathComponent("alpha.log"), in: logs)
        guard case let .failed(reason) = rotation else {
            Issue.record("rotated through a symbolic link: \(rotation)")
            return
        }
        #expect(reason.hasPrefix("cannot open"))
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("alpha.log").path))
        // A log outside the logs directory is not touched.
        let outside = VPhoneLaunchpadConsoleLog.rotate(real.appendingPathComponent("alpha.log"), in: temp.url)
        #expect(outside == .failed("\(real.appendingPathComponent("alpha.log").path) is not in \(temp.url.standardizedFileURL.path)"))
        // Another machine's log (a machine named `alpha.1`) is not replaced.
        try FileManager.default.removeItem(at: logs)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "alpha\n".write(to: logs.appendingPathComponent("alpha.log"), atomically: true, encoding: .utf8)
        try "alpha.1\n".write(to: logs.appendingPathComponent("alpha.1.log"), atomically: true, encoding: .utf8)
        let reserved: Set<URL> = [logs.appendingPathComponent("alpha.1.log")]
        #expect(VPhoneLaunchpadConsoleLog.rotate(logs.appendingPathComponent("alpha.log"), in: logs, reserved: reserved)
            == .failed("alpha.1.log is the console log of another machine"))
        #expect(read(logs.appendingPathComponent("alpha.1.log")) == "alpha.1\n")
        // A directory in place of the log is left alone.
        try FileManager.default.removeItem(at: logs.appendingPathComponent("alpha.log"))
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("alpha.log"), withIntermediateDirectories: true)
        #expect(VPhoneLaunchpadConsoleLog.rotate(logs.appendingPathComponent("alpha.log"), in: logs)
            == .failed("alpha.log is not a regular file"))
    }
}

// MARK: - Log follower

struct LogFollowerTests {
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func followsAppendsAndReportsAMissingFileOnce() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-follow")
        let log = temp.url.appendingPathComponent("m.log")
        var follower = VPhoneLaunchpadLogFollower(url: log)
        #expect(follower.poll() == [.missing])
        #expect(follower.poll() == [])

        try "a\nb\n".write(to: log, atomically: false, encoding: .utf8)
        #expect(follower.poll() == [.reset, .lines(["a", "b"])])
        #expect(follower.poll() == [])
        try append("c\nhalf", to: log)
        #expect(follower.poll() == [.lines(["c"])])
        try append(" line\n\u{1B}[31mred\u{1B}[0m\rprogress 1\rprogress 2\n", to: log)
        #expect(follower.poll() == [.lines(["half line", "red", "progress 1", "progress 2"])])
    }

    @Test func resetsWhenTheFileIsTruncated() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-follow")
        let log = temp.url.appendingPathComponent("m.log")
        try "first run line 1\nfirst run line 2\n".write(to: log, atomically: false, encoding: .utf8)
        var follower = VPhoneLaunchpadLogFollower(url: log)
        #expect(follower.poll() == [.lines(["first run line 1", "first run line 2"])])
        let number = try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int
        // Same file, shorter than what was read.
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("new\n".utf8))
        try handle.close()
        #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int == number)
        #expect(follower.poll() == [.reset, .lines(["new"])])
    }

    @Test func resetsWhenTheFileIsReplaced() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-follow")
        let log = temp.url.appendingPathComponent("m.log")
        try "old run\n".write(to: log, atomically: false, encoding: .utf8)
        var follower = VPhoneLaunchpadLogFollower(url: log)
        #expect(follower.poll() == [.lines(["old run"])])
        // A longer file under a new file number, as a new `vm launch` makes.
        let replacement = temp.url.appendingPathComponent("m.log.new")
        try "new run line 1\nnew run line 2\n".write(to: replacement, atomically: false, encoding: .utf8)
        #expect(rename(replacement.path, log.path) == 0)
        #expect(follower.poll() == [.reset, .lines(["new run line 1", "new run line 2"])])
        // A removed file keeps what was shown until a new one appears.
        try FileManager.default.removeItem(at: log)
        #expect(follower.poll() == [])
        try "third\n".write(to: log, atomically: false, encoding: .utf8)
        #expect(follower.poll() == [.reset, .lines(["third"])])
    }

    @Test func replaysOnlyTheTailFromALineStart() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-follow")
        let log = temp.url.appendingPathComponent("m.log")
        try "0123456789\nabcdefgh\nlast\n".write(to: log, atomically: false, encoding: .utf8)
        // 12 bytes back from the end lands inside "abcdefgh".
        var follower = VPhoneLaunchpadLogFollower(url: log, replayBytes: 12)
        #expect(follower.poll() == [.lines(["last"])])
        #expect(VPhoneLaunchpadLogFollower.defaultReplayBytes == 4 << 20)
    }
}

// MARK: - Create checkpoint summary

struct CreateSummaryTests {
    private func checkpoint(for bundle: URL, variant: String) -> VPhoneCreateCheckpoint {
        let options = VPhoneCreateEffectiveOptions(
            variant: variant, iphoneSource: nil, cloudosSource: nil, spoofBuild: nil, forceDscMaxSlide: false,
            enableFrida: false, cpuCount: 2, memoryMb: 1024, diskSizeGb: 8)
        return VPhoneCreateCheckpoint(
            identity: .init(name: bundle.lastPathComponent, path: bundle.path, directoryId: "1:2"), options: options,
            tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func write(_ checkpoint: VPhoneCreateCheckpoint, to bundle: URL) throws {
        let directory = bundle.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try VPhoneCreateJSON.encoder.encode(checkpoint)
            .write(to: directory.appendingPathComponent(VPhoneCreateCheckpointStore.fileName))
    }

    @Test func noCheckpointIsNil() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-summary")
        try LaunchpadReports.writeBundle(named: "plain", in: temp.url)
        #expect(VPhoneLaunchpadCreateSummary.read(VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "plain")) == nil)
    }

    @Test func statusesKeepTheirCheckpointSpelling() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-summary")
        let bundle = try LaunchpadReports.writeBundle(named: "made", in: temp.url).url
        var record = checkpoint(for: bundle, variant: "regular")
        for index in record.stages.indices where record.stages[index].status != .notApplicable {
            record.stages[index].status = .succeeded
            record.stages[index].attemptId = record.attemptId
            record.stages[index].executorResult = "completed"
            record.stages[index].verifierVersion = "test"
            record.stages[index].startedAt = Date(timeIntervalSince1970: 1_800_000_000)
            record.stages[index].finishedAt = Date(timeIntervalSince1970: 1_800_000_100)
        }
        let verification = try #require(record.stages.firstIndex { $0.stage == .verification })
        record.stages[verification].status = .unverified
        record.stages[verification].reason = "no evidence"
        try write(record, to: bundle)

        let summary = try #require(try VPhoneLaunchpadCreateSummary.read(
            VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "made"))?.get())
        #expect(summary.overallStatus == "completed_unverified")
        #expect(summary.variant == "regular")
        #expect(summary.nextStage == nil)
        #expect(summary.stages.map(\.name) == VPhoneCreateStage.allCases.map(\.rawValue))
        #expect(summary.stages.first { $0.name == "jb_finalize" }?.status == "not_applicable")
        #expect(summary.stages.last?.status == "unverified")
        #expect(summary.recovery == nil)
    }

    @Test func runningStageReadsAsInterruptedAndUnreadableIsAFailure() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-summary")
        let bundle = try LaunchpadReports.writeBundle(named: "busy", in: temp.url).url
        var record = checkpoint(for: bundle, variant: "jb")
        record.stages[0].status = .running
        record.stages[0].attemptId = record.attemptId
        record.stages[0].startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try write(record, to: bundle)
        let path = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "busy")
        let summary = try #require(try VPhoneLaunchpadCreateSummary.read(path)?.get())
        #expect(summary.overallStatus == "interrupted")
        #expect(summary.nextStage == "prepare")

        try Data("{".utf8).write(to: bundle.appendingPathComponent(".create-checkpoint/checkpoint.json"))
        guard case let .failure(error)? = VPhoneLaunchpadCreateSummary.read(path) else {
            Issue.record("expected a read failure")
            return
        }
        #expect(error.message.contains("unreadable"))
    }
}
