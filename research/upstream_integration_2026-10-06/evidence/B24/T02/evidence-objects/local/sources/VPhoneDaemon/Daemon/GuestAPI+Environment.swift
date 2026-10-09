import Darwin
import Foundation
import IcliSystem
import VphonedNative

// MARK: - vphone Environment

/// The environment update keeps the libraries in /usr/lib in step with the
/// host. The host uploads each changed library to the staging directory, then
/// asks for the set to be installed (T17: `vphone-cli guest env update`).
///
/// Local differences from upstream 2.2.3: install replaces only libraries
/// that are already installed, keeps a backup and journal per transaction,
/// reports a partial failure as a result instead of an error, and restarts
/// no process. `environment.loaded` reports which processes map the
/// installed file or a replaced copy; `environment.restore` puts back the
/// libraries a transaction replaced.
extension GuestAPI {
    /// Must match `scripts/guest_environment.json` (tests/test_cfw_env_update.py).
    static let environmentLibraries = [
        "launchdhook-vphone.dylib",
        "SystemHook-vphone.dylib",
        "libvcamcaptured.dylib",
        "libcamfix.dylib",
        "libvlocation.dylib",
    ]
    static let environmentStaging = "/var/root/Library/Caches/vphone-environment"
    static let environmentLoadAlias = "/vh"

    static var environmentTransaction: EnvironmentTransaction {
        EnvironmentTransaction(libraries: environmentLibraries, libraryDirectory: "/usr/lib",
                               stagingDirectory: environmentStaging)
    }

    static func executeEnvironment(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "environment.status":
            let transaction = environmentTransaction
            var alias: [String: Any] = ["path": environmentLoadAlias, "target": NSNull()]
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: environmentLoadAlias) {
                alias["target"] = target
            }
            return [
                "libraries": transaction.status(),
                "staging": environmentStaging,
                "root_read_only": try isRootReadOnly(),
                "load_alias": alias,
                "transactions": Array(transaction.transactions().prefix(10)),
            ]
        case "environment.install":
            return try installEnvironment(params)
        case "environment.restore":
            return try restoreEnvironment(params)
        case "environment.loaded":
            return try loadedEnvironment(params)
        default:
            return nil
        }
    }

    private static func isRootReadOnly() throws -> Bool {
        var root = statfs()
        guard statfs("/", &root) == 0 else {
            throw GuestAPIError.operationFailed("statfs(/): \(String(cString: strerror(errno)))")
        }
        return root.f_flags & UInt32(MNT_RDONLY) != 0
    }

    private static func installEnvironment(_ params: [String: Any]) throws -> [String: Any] {
        let transaction = environmentTransaction
        let entries: [(name: String, sha256: String)]
        do { entries = try transaction.validate(params["libraries"]) } catch {
            throw GuestAPIError.invalidRequest(String(describing: error))
        }
        var journal: EnvironmentJournal
        do { journal = try transaction.prepare(entries) } catch {
            throw GuestAPIError.operationFailed(String(describing: error))
        }
        let rootReadOnly: Bool
        do {
            rootReadOnly = try withWritableRoot { transaction.apply(&journal, replace: installLibrary) }
        } catch {
            // The writable remount failed before any replacement.
            if journal.state == "prepared" {
                transaction.abandon(&journal, reason: String(describing: error))
            }
            throw GuestAPIError.operationFailed("\(error) (transaction \(journal.id), state \(journal.state))")
        }
        let installed = journal.libraries.filter { $0.state == "replaced" }.map(\.name)
        var result = journal.dictionary
        result["complete"] = journal.state == "complete"
        result["installed"] = installed
        result["journal"] = transaction.stateDirectory + "/" + journal.id + "/journal.json"
        // No process is restarted here; the host asks for that explicitly.
        result["restarted_pids"] = [Int]()
        // launchd loaded its hook at boot and keeps the old copy mapped.
        // false does not mean that running processes loaded the new files.
        result["reboot_required"] = !rootReadOnly || installed.contains("launchdhook-vphone.dylib")
        result["root_read_only"] = rootReadOnly
        return result
    }

    private static func restoreEnvironment(_ params: [String: Any]) throws -> [String: Any] {
        let transaction = environmentTransaction
        var journal: EnvironmentJournal
        do { journal = try transaction.prepareRestore(id: string(params, "transaction")) } catch {
            throw GuestAPIError.invalidRequest(String(describing: error))
        }
        let rootReadOnly = try withWritableRoot { transaction.applyRestore(&journal, replace: installLibrary) }
        let restored = journal.libraries.filter { $0.state == "restored" }.map(\.name)
        var result = journal.dictionary
        result["restored"] = restored
        result["reboot_required"] = !rootReadOnly || restored.contains("launchdhook-vphone.dylib")
        result["root_read_only"] = rootReadOnly
        return result
    }

    /// Processes that map an environment library: the installed file
    /// (`current`) or a replaced copy (`stale`). `processes` limits the scan
    /// to exact process names; without it every process is scanned.
    private static func loadedEnvironment(_ params: [String: Any]) throws -> [String: Any] {
        let names = params["processes"] as? [String]
        let transaction = environmentTransaction
        let current = transaction.identities()
        let previous = transaction.previousIdentities()
        let rows = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
        var buffer = [VPMappedFile](repeating: VPMappedFile(), count: 4096)
        var processes: [[String: Any]] = []
        var uninspected: [[String: Any]] = []
        var scanned = 0
        for row in rows {
            guard let pid = row["pid"] as? Int, pid > 0 else { continue }
            let name = row["name"] as? String ?? ""
            if let names, !names.contains(name) { continue }
            scanned += 1
            let count = buffer.withUnsafeMutableBufferPointer {
                vp_process_mapped_files(Int32(pid), $0.baseAddress, Int32($0.count), nil)
            }
            guard count >= 0 else {
                let code = errno
                if code != ESRCH { uninspected.append(["pid": pid, "name": name, "errno": Int(code)]) }
                continue
            }
            let regions = buffer.prefix(Int(count)).map { file in
                var copy = file
                let path = withUnsafeBytes(of: &copy.path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return EnvironmentMapping(path: path, device: file.device, inode: file.inode)
            }
            let mappings = transaction.classify(regions, current: current, previous: previous)
            if !mappings.isEmpty {
                processes.append(["pid": pid, "name": name, "mappings": mappings])
            }
        }
        return [
            "libraries": environmentLibraries.map { name -> [String: Any] in
                guard let identity = current[name] else { return ["name": name, "device": NSNull(), "inode": NSNull()] }
                return ["name": name, "device": Int(identity.device), "inode": Int(identity.inode)]
            },
            "processes": processes,
            "uninspected": uninspected,
            "scanned": scanned,
        ]
    }

    /// Runs `body` with `/` writable, then tries to restore read-only state.
    /// Some APFS guests reject a live read-only remount; the caller must then
    /// request a reboot so jailbreak detection does not keep seeing rootful.
    private static func withWritableRoot(_ body: () throws -> Void) throws -> Bool {
        if try isRootReadOnly() {
            try remountRoot("-w")
        }
        let result = Result { try body() }
        let rootReadOnly: Bool
        do {
            try remountRoot("-r")
            rootReadOnly = true
        } catch {
            NSLog("[environment] root remains writable until reboot: %@", String(describing: error))
            rootReadOnly = false
        }
        try result.get()
        return rootReadOnly
    }

    /// `mode` is `-w` for read-write or `-r` for read-only.
    private static func remountRoot(_ mode: String) throws {
        let arguments = ["/sbin/mount", "-u", mode, "/"]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else {
            throw GuestAPIError.operationFailed("pipe: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, errorPipe[0])
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, nil, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        close(errorPipe[1])
        guard spawned == 0 else {
            close(errorPipe[0])
            throw GuestAPIError.operationFailed("mount -u \(mode) /: \(String(cString: strerror(spawned)))")
        }
        var errorText = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while errorText.count < 4096 {
            let count = read(errorPipe[0], &buffer, min(buffer.count, 4096 - errorText.count))
            if count <= 0 { break }
            errorText.append(contentsOf: buffer.prefix(count))
        }
        close(errorPipe[0])
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid, status == 0 else {
            let details = String(data: errorText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GuestAPIError.operationFailed("mount -u \(mode) / exited with status \(status): \(details)")
        }
    }

    /// Copies onto the system volume first, so the rename that replaces the
    /// library is atomic. Running processes keep the copy they mapped.
    private static func installLibrary(from source: String, to destination: String) throws {
        let temporary = destination + ".vphoned-" + UUID().uuidString
        try FileManager.default.copyItem(atPath: source, toPath: temporary)
        guard chown(temporary, 0, 0) == 0, chmod(temporary, 0o755) == 0, rename(temporary, destination) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw GuestAPIError.operationFailed("Could not install \(destination): \(reason)")
        }
    }
}
