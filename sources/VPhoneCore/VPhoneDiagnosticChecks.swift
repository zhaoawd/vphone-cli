import Darwin
import Foundation
import Security

// MARK: - Probes

/// Everything `doctor` observes outside plain file reads, injectable for tests.
///
/// Every probe is read-only. Lock probes take a non-blocking flock and release
/// it at once (the pattern of `vm create-status`); they never wait and never
/// write a runtime record.
public struct VPhoneDiagnosticProbes: Sendable {
    public enum HostControlAnswer: Equatable, Sendable {
        case missing
        case notSocket
        case connectFailed(String)
        case noResponse(String)
        case capabilities(guestConnected: Bool, screenAvailable: Bool?, protocolVersion: Int?, guestCapabilityCount: Int)
        /// The socket answered with `ok:false` (e.g. a VM built before the command existed).
        case rejected(String)
    }

    /// Process environment. Checks read only whether a variable is set, never print a value.
    public var environment: [String: String]
    public var operatingSystemVersion: @Sendable () -> OperatingSystemVersion
    public var sysctlInt: @Sendable (String) -> Int?
    /// Bounded subprocess with stdin at /dev/null; nil when it cannot be launched.
    public var run: @Sendable (_ executable: URL, _ args: [String], _ env: [String: String]?, _ timeout: TimeInterval) -> VPhoneProcessResult?
    /// Entitlement of this process: true/false, nil when it cannot be determined.
    public var hasEntitlement: @Sendable (String) -> Bool?
    public var executableURL: @Sendable () -> URL
    /// Resolved path of a command as the scripts' `command -v` would find it.
    public var findExecutable: @Sendable (String) -> String?
    /// `ps -axo pid=,command=`; nil when unavailable.
    public var processList: @Sendable () -> String?
    /// Image paths from `hdiutil info`; nil when unavailable.
    public var attachedImages: @Sendable () -> [String]?
    public var bundleLockHeld: @Sendable (URL) -> Bool
    public var createRunLockHeld: @Sendable (URL) -> Bool
    public var libraryLockHeld: @Sendable (URL) -> Bool
    public var processIdentity: @Sendable (pid_t) -> VPhoneProcessIdentity?
    /// Sends one `{"t":"capabilities"}` request (read-only) to a host control socket.
    public var hostControlCapabilities: @Sendable (String) -> HostControlAnswer
    public var freeBytes: @Sendable (URL) -> Int64?

    public init(
        environment: [String: String],
        operatingSystemVersion: @escaping @Sendable () -> OperatingSystemVersion,
        sysctlInt: @escaping @Sendable (String) -> Int?,
        run: @escaping @Sendable (URL, [String], [String: String]?, TimeInterval) -> VPhoneProcessResult?,
        hasEntitlement: @escaping @Sendable (String) -> Bool?,
        executableURL: @escaping @Sendable () -> URL,
        findExecutable: @escaping @Sendable (String) -> String?,
        processList: @escaping @Sendable () -> String?,
        attachedImages: @escaping @Sendable () -> [String]?,
        bundleLockHeld: @escaping @Sendable (URL) -> Bool,
        createRunLockHeld: @escaping @Sendable (URL) -> Bool,
        libraryLockHeld: @escaping @Sendable (URL) -> Bool,
        processIdentity: @escaping @Sendable (pid_t) -> VPhoneProcessIdentity?,
        hostControlCapabilities: @escaping @Sendable (String) -> HostControlAnswer,
        freeBytes: @escaping @Sendable (URL) -> Int64?
    ) {
        self.environment = environment
        self.operatingSystemVersion = operatingSystemVersion
        self.sysctlInt = sysctlInt
        self.run = run
        self.hasEntitlement = hasEntitlement
        self.executableURL = executableURL
        self.findExecutable = findExecutable
        self.processList = processList
        self.attachedImages = attachedImages
        self.bundleLockHeld = bundleLockHeld
        self.createRunLockHeld = createRunLockHeld
        self.libraryLockHeld = libraryLockHeld
        self.processIdentity = processIdentity
        self.hostControlCapabilities = hostControlCapabilities
        self.freeBytes = freeBytes
    }

    public static func live() -> VPhoneDiagnosticProbes {
        let environment = ProcessInfo.processInfo.environment
        let executable = VPhoneResources.runningExecutable()
        return VPhoneDiagnosticProbes(
            environment: environment,
            operatingSystemVersion: { ProcessInfo.processInfo.operatingSystemVersion },
            sysctlInt: { name in
                var value: Int32 = 0
                var size = MemoryLayout<Int32>.size
                guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
                return Int(value)
            },
            run: { executable, args, env, timeout in
                try? VPhoneProcessRunner.runCapturing(executable, args, env: env, timeout: timeout)
            },
            hasEntitlement: { key in
                guard let task = SecTaskCreateFromSelf(nil) else { return nil }
                let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
                return (value as? Bool) == true
            },
            executableURL: { executable },
            findExecutable: { name in
                let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
                    + [executable.deletingLastPathComponent().path]
                for directory in directories where !directory.isEmpty {
                    let path = directory + "/" + name
                    if FileManager.default.isExecutableFile(atPath: path) { return path }
                }
                return nil
            },
            processList: {
                guard let result = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="], timeout: 10), result.succeeded
                else { return nil }
                return result.stdout
            },
            attachedImages: {
                guard let result = try? VPhoneProcessRunner.runCapturing(
                    URL(fileURLWithPath: "/usr/bin/hdiutil"), ["info", "-plist"], timeout: 15), result.succeeded,
                    let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any]
                else { return nil }
                return ((plist["images"] as? [[String: Any]]) ?? []).compactMap { $0["image-path"] as? String }
            },
            bundleLockHeld: { VPhoneVMLockProbe.isLockHeld(directory: $0) },
            createRunLockHeld: { VPhoneCreateCheckpointStore.isRunLockHeld(bundleURL: $0) },
            libraryLockHeld: { VPhoneLibraryLockProbe.isLockHeld(root: $0) },
            processIdentity: { VPhoneProcessInfo.identity(of: $0) },
            hostControlCapabilities: { VPhoneDiagnosticProbes.queryCapabilities(socketPath: $0) },
            freeBytes: { url in
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            })
    }

    /// One read-only request on the host control socket. The request changes
    /// no VM or guest state (see research/host_control_e2_2026-09-12.md).
    static func queryCapabilities(socketPath: String, timeout: TimeInterval = 3) -> HostControlAnswer {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .notSocket }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { return .connectFailed("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .connectFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .connectFailed(String(cString: strerror(errno))) }
        let request = Array("{\"t\":\"capabilities\"}\n".utf8)
        guard write(fd, request, request.count) == request.count else {
            return .noResponse("write failed: \(String(cString: strerror(errno)))")
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count < 0 { return .noResponse("read failed: \(String(cString: strerror(errno)))") }
                break
            }
            response.append(contentsOf: buffer[..<count])
            if buffer[..<count].contains(10) { break }
        }
        guard let line = response.split(separator: 10).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let ok = object["ok"] as? Bool
        else { return .noResponse("no valid JSON response") }
        guard ok else { return .rejected(object["error"] as? String ?? "request rejected") }
        return .capabilities(
            guestConnected: object["guest_connected"] as? Bool ?? false,
            screenAvailable: object["screen_available"] as? Bool,
            protocolVersion: object["protocol_version"] as? Int,
            guestCapabilityCount: (object["guest_capabilities"] as? [Any])?.count ?? 0)
    }
}

// MARK: - VPhoneDiagnostics

/// Read-only checks behind `vphone-cli doctor`. Nothing here takes a blocking
/// lock, writes a file, boots, mounts, restores or asks for privileges.
public struct VPhoneDiagnostics: Sendable {
    public static let requiredEntitlements = [
        "com.apple.security.virtualization",
        "com.apple.private.virtualization",
        "com.apple.private.virtualization.security-research",
    ]
    /// Below this free space on the library volume a new create is reported as at risk.
    public static let lowDiskSpaceBytes: Int64 = 50 * 1024 * 1024 * 1024

    public let resources: VPhoneResources
    public let library: VPhoneLibrary
    public let probes: VPhoneDiagnosticProbes

    public init(resources: VPhoneResources, library: VPhoneLibrary, probes: VPhoneDiagnosticProbes) {
        self.resources = resources
        self.library = library
        self.probes = probes
    }

    /// Host facts shared by every bundle in one run, so `ps`/`hdiutil` run once.
    public struct Snapshot: Sendable {
        public var processList: String?
        public var attachedImages: [String]?

        public init(processList: String?, attachedImages: [String]?) {
            self.processList = processList
            self.attachedImages = attachedImages
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(processList: probes.processList(), attachedImages: probes.attachedImages())
    }

    /// Host checks, then either one VM (with the guest probe) or a library summary.
    public func run(vm name: String?) -> [VPhoneDiagnosticFinding] {
        let snapshot = snapshot()
        var findings = hostFindings(snapshot)
        if let name {
            findings += vmFindings(name: name, snapshot: snapshot, probeGuest: true)
        } else {
            findings += libraryFindings(snapshot)
        }
        return findings
    }

    // MARK: Host

    public func hostFindings(_ snapshot: Snapshot) -> [VPhoneDiagnosticFinding] {
        [macOSVersion(), hypervisorSupport(), nestedVirtualization(), sipStatus(), researchGuests(),
         signing(snapshot), diskSpace(), pythonRuntime(), runtimeResources(), hostTools(),
         libraryLock(), runningVMs(snapshot)]
    }

    func macOSVersion() -> VPhoneDiagnosticFinding {
        let version = probes.operatingSystemVersion()
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        guard version.majorVersion >= 15 else {
            return .init(.environment, .macosVersion, .error, "macOS 15 or later is required for PV=3 VMs",
                         evidence: ["macos": text])
        }
        return .init(.environment, .macosVersion, .ok, "macOS \(text)", evidence: ["macos": text])
    }

    func hypervisorSupport() -> VPhoneDiagnosticFinding {
        switch probes.sysctlInt("kern.hv_support") {
        case 1: .init(.environment, .hypervisorSupport, .ok, "Hypervisor support is available", evidence: ["kern.hv_support": "1"])
        case let value?: .init(.environment, .hypervisorSupport, .error, "this host reports no Hypervisor support",
                               evidence: ["kern.hv_support": "\(value)"])
        case nil: .init(.environment, .hypervisorSupport, .unknown, "kern.hv_support could not be read")
        }
    }

    func nestedVirtualization() -> VPhoneDiagnosticFinding {
        switch probes.sysctlInt("kern.hv_vmm_present") {
        case 0: .init(.environment, .nestedVirtualization, .ok, "host is not itself a VM", evidence: ["kern.hv_vmm_present": "0"])
        case let value?: .init(.environment, .nestedVirtualization, .error,
                               "host is a virtual machine; Virtualization.framework guest boot is unavailable",
                               evidence: ["kern.hv_vmm_present": "\(value)"])
        case nil: .init(.environment, .nestedVirtualization, .unknown, "kern.hv_vmm_present could not be read")
        }
    }

    func sipStatus() -> VPhoneDiagnosticFinding {
        guard let result = probes.run(URL(fileURLWithPath: "/usr/bin/csrutil"), ["status"], nil, 5),
              !result.timedOut, result.succeeded
        else { return .init(.environment, .sipStatus, .unknown, "csrutil status could not be run") }
        let output = result.stdout
        var evidence: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, ["enabled", "disabled"].contains(parts[1]) { evidence[parts[0]] = parts[1] }
        }
        if output.contains("status: disabled.") {
            return .init(.environment, .sipStatus, .ok, "SIP is disabled", evidence: evidence)
        }
        if output.contains("status: enabled.") || output.contains("Custom Configuration") {
            let custom = output.contains("Custom Configuration")
            evidence["status"] = custom ? "custom configuration" : "enabled"
            return .init(.environment, .sipStatus, .warning,
                         "SIP is \(custom ? "partially" : "fully") enabled; launching the signed binary depends on an AMFI bypass such as amfidont",
                         evidence: evidence, action: "make amfidont_allow_vphone (or disable SIP from Recovery OS)")
        }
        return .init(.environment, .sipStatus, .unknown, "csrutil status output was not recognized")
    }

    func researchGuests() -> VPhoneDiagnosticFinding {
        guard let result = probes.run(URL(fileURLWithPath: "/usr/bin/csrutil"), ["allow-research-guests", "status"], nil, 5),
              !result.timedOut
        else { return .init(.environment, .researchGuests, .unknown, "csrutil allow-research-guests status could not be run") }
        let output = result.stdout + result.stderr
        if output.contains("Pick a macOS installation") {
            return .init(.environment, .researchGuests, .unknown,
                         "several macOS installations are present; run scripts/boot_host_preflight.sh to select one")
        }
        if output.contains("status: enabled") {
            return .init(.environment, .researchGuests, .ok, "research guests are allowed")
        }
        if output.contains("status: disabled") {
            return .init(.environment, .researchGuests, .error, "research guests are not allowed; PV=3 VMs cannot boot",
                         action: "csrutil allow-research-guests enable (from Recovery OS)")
        }
        return .init(.environment, .researchGuests, .unknown, "csrutil allow-research-guests status output was not recognized")
    }

    func signing(_ snapshot: Snapshot) -> VPhoneDiagnosticFinding {
        var evidence = ["executable": probes.executableURL().path]
        if let ps = snapshot.processList {
            evidence["amfidont_running"] = ps.contains("amfidont") ? "true" : "false"
        }
        var missing: [String] = []
        for key in Self.requiredEntitlements {
            switch probes.hasEntitlement(key) {
            case true?: break
            case false?: missing.append(key)
            case nil:
                return .init(.environment, .signingEntitlements, .unknown,
                             "the entitlements of this process could not be read", evidence: evidence)
            }
        }
        guard missing.isEmpty else {
            evidence["missing"] = missing.joined(separator: ", ")
            return .init(.environment, .signingEntitlements, .error,
                         "this vphone-cli binary lacks the private virtualization entitlements; it can diagnose but not boot",
                         evidence: evidence, action: "make build (then run .build/vphone-cli.app/Contents/MacOS/vphone-cli)")
        }
        return .init(.environment, .signingEntitlements, .ok,
                     "running with the virtualization entitlements, so this host allowed the signed binary to launch",
                     evidence: evidence)
    }

    func diskSpace() -> VPhoneDiagnosticFinding {
        var probe = library.root
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        guard let free = probes.freeBytes(probe) else {
            return .init(.environment, .diskSpace, .unknown, "free space of the library volume could not be read",
                         evidence: ["volume_path": probe.path])
        }
        let evidence = ["volume_path": probe.path, "free_gib": String(free / (1024 * 1024 * 1024))]
        guard free >= Self.lowDiskSpaceBytes else {
            return .init(.environment, .diskSpace, .warning,
                         "less than \(Self.lowDiskSpaceBytes / (1024 * 1024 * 1024)) GiB free on the library volume; a create may run out of space",
                         evidence: evidence)
        }
        return .init(.environment, .diskSpace, .ok, "free space on the library volume", evidence: evidence)
    }

    // MARK: Dependencies

    /// Mirrors `VPhoneResources.pythonExecutable()` selection without bootstrapping.
    func pythonRuntime() -> VPhoneDiagnosticFinding {
        guard FileManager.default.fileExists(atPath: resources.pythonRuntimeCheckScript.path) else {
            return .init(.dependency, .pythonRuntime, .unknown,
                         "scripts/check_python_runtime.py is missing, so no interpreter can be verified (see runtime_resources)",
                         evidence: ["resource_base": resources.base.path])
        }
        var env = probes.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        var failures: [String] = []
        var evidence: [String: String] = [:]
        for candidate in resources.pythonCandidates {
            let label = candidate.source.rawValue
            // The override path comes from the environment; report only that it was used.
            let shown = candidate.source == .environmentOverride ? "(from VPHONE_PYTHON)" : candidate.url.path
            guard FileManager.default.isExecutableFile(atPath: candidate.url.path) else {
                failures.append("\(label): not an executable at \(shown)")
                if candidate.source == .environmentOverride { break }
                continue
            }
            guard let result = probes.run(candidate.url, [resources.pythonRuntimeCheckScript.path, "--locked", "--json"], env, 60) else {
                failures.append("\(label): could not be launched")
                if candidate.source == .environmentOverride { break }
                continue
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
            if result.succeeded, object?["ok"] as? Bool == true {
                evidence["source"] = label
                evidence["python"] = shown
                evidence["version"] = object?["version"] as? String ?? "unknown"
                evidence["lock"] = (object?["lock"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
                if !failures.isEmpty { evidence["skipped"] = failures.joined(separator: "; ") }
                return .init(.dependency, .pythonRuntime, .ok, "locked Python runtime verified", evidence: evidence)
            }
            var reason = result.timedOut ? "runtime check timed out" : (object?["error"] as? String ?? "runtime check failed (exit \(result.exitCode))")
            if let differences = object?["differences"] as? [String: Any], !differences.isEmpty {
                reason = "installed packages differ from the lock: " + differences.keys.sorted().joined(separator: ", ")
            }
            failures.append("\(label): \(reason)")
            if candidate.source == .environmentOverride { break }
        }
        evidence["candidates"] = failures.joined(separator: "; ")
        return .init(.dependency, .pythonRuntime, .error, "no Python runtime passes the locked capability check",
                     evidence: evidence, action: probes.environment["VPHONE_PYTHON"].map { _ in "unset VPHONE_PYTHON or point it at a verified interpreter" }
                        ?? "vphone-cli setup (or make setup_venv in a checkout)")
    }

    func runtimeResources() -> VPhoneDiagnosticFinding {
        var missing: [String] = []
        for url in resources.runtimeResources {
            var info = stat()
            if stat(url.path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG || info.st_size == 0 {
                missing.append(url.path.hasPrefix(resources.base.path + "/")
                    ? String(url.path.dropFirst(resources.base.path.count + 1)) : url.path)
            }
        }
        var evidence = ["resource_base": resources.base.path, "checked": "\(resources.runtimeResources.count)"]
        guard missing.isEmpty else {
            evidence["missing"] = missing.joined(separator: ", ")
            return .init(.dependency, .runtimeResources, .error, "\(missing.count) runtime resource(s) are missing or empty",
                         evidence: evidence, action: "make build (app) or git submodule update --init and make setup_tools (checkout)")
        }
        return .init(.dependency, .runtimeResources, .ok, "runtime resources are present", evidence: evidence)
    }

    /// Commands the shell stages look up with `command -v`.
    static let requiredTools = ["ipsw", "aea", "ldid", "gtar"]
    static let downloaders = ["aria2c", "curl", "wget"]
    static let jailbreakTools = ["zstd", "xcrun"]

    func hostTools() -> VPhoneDiagnosticFinding {
        var evidence: [String: String] = [:]
        var missingRequired: [String] = []
        var missingJailbreak: [String] = []
        for tool in Self.requiredTools {
            if let path = probes.findExecutable(tool) { evidence[tool] = path } else { evidence[tool] = "missing"; missingRequired.append(tool) }
        }
        let downloader = Self.downloaders.lazy.compactMap { name in self.probes.findExecutable(name).map { (name, $0) } }.first
        evidence["downloader"] = downloader.map { "\($0.0) \($0.1)" } ?? "missing"
        if downloader == nil { missingRequired.append("aria2c|curl|wget") }
        for tool in Self.jailbreakTools {
            if let path = probes.findExecutable(tool) { evidence[tool] = path } else { evidence[tool] = "missing"; missingJailbreak.append(tool) }
        }
        evidence["search"] = "PATH of this process, then the vphone-cli executable directory"
        if !missingRequired.isEmpty {
            return .init(.dependency, .hostTools, .error, "required host tools are missing: " + missingRequired.joined(separator: ", "),
                         evidence: evidence, action: "make setup_tools")
        }
        if !missingJailbreak.isEmpty {
            return .init(.dependency, .hostTools, .warning, "tools needed only by jb/exp CFW are missing: " + missingJailbreak.joined(separator: ", "),
                         evidence: evidence, action: "make setup_tools")
        }
        return .init(.dependency, .hostTools, .ok, "host tools are present", evidence: evidence)
    }

    // MARK: Host occupancy

    func libraryLock() -> VPhoneDiagnosticFinding {
        guard FileManager.default.fileExists(atPath: library.root.path) else {
            return .init(.occupancy, .libraryLock, .ok, "library root does not exist, so nothing holds its lock")
        }
        if probes.libraryLockHeld(library.root) {
            return .init(.occupancy, .libraryLock, .ok, "a create or import is placing a VM name in the library now",
                         evidence: ["held": "true"])
        }
        return .init(.occupancy, .libraryLock, .ok, "library lock is free", evidence: ["held": "false"])
    }

    func runningVMs(_ snapshot: Snapshot) -> VPhoneDiagnosticFinding {
        guard let ps = snapshot.processList else {
            return .init(.occupancy, .runningVMProcesses, .unknown, "the process list could not be read")
        }
        let configs = Self.bootProcesses(ps)
        var evidence = ["count": "\(configs.count)"]
        for (pid, config) in configs { evidence["pid_\(pid)"] = config }
        return .init(.occupancy, .runningVMProcesses, .ok,
                     configs.isEmpty ? "no vphone-cli VM process is running" : "\(configs.count) vphone-cli VM process(es) running",
                     evidence: evidence)
    }

    /// `(pid, config path)` of every `vphone-cli ... --config <path>` process.
    static func bootProcesses(_ ps: String) -> [(Int32, String)] {
        ps.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, let pid = Int32(fields[0]),
                  fields[1].hasSuffix("/vphone-cli") || fields[1] == "vphone-cli",
                  let index = fields.firstIndex(of: "--config"), index + 1 < fields.count
            else { return nil }
            return (pid, fields[index + 1])
        }
    }

    /// Boot processes of one bundle. `VPhoneBootProcessLocator` also matches a
    /// `--config` path containing `..` or symlinks (a launcher started from
    /// another directory).
    static func bootPIDs(_ ps: String, bundleURL: URL) -> [Int32] {
        VPhoneBootProcessLocator.parsePIDs(ps, configURL: bundleURL.appendingPathComponent("config.plist"))
    }

    // MARK: Library

    public func libraryFindings(_ snapshot: Snapshot) -> [VPhoneDiagnosticFinding] {
        guard FileManager.default.fileExists(atPath: library.root.path) else {
            return [.init(.input, .libraryRoot, .ok, "library root does not exist yet",
                          evidence: ["library_root": library.root.path])]
        }
        let scan: (bundles: [VPhoneBundle], skipped: [VPhoneLibrarySkip])
        do { scan = try library.scan() } catch {
            return [.init(.internal, .checkFailed, .unknown, "the library could not be listed: \(error)")]
        }
        var findings: [VPhoneDiagnosticFinding] = [
            .init(.input, .libraryRoot, .ok, "\(scan.bundles.count) VM bundle(s), \(scan.skipped.count) unreadable",
                  evidence: ["library_root": library.root.path, "bundles": scan.bundles.map(\.name).joined(separator: ", ")]),
        ]
        for skip in scan.skipped {
            findings.append(.init(.input, .bundleUnreadable, .error, "config.plist cannot be loaded",
                                  evidence: ["reason": skip.reason], action: "vphone-cli doctor \(skip.name)", vm: skip.name))
        }
        // Per-bundle detail is only repeated here when it is not ok; `doctor <name>` shows everything.
        for bundle in scan.bundles {
            let problems = vmFindings(name: bundle.name, snapshot: snapshot, probeGuest: false).filter { $0.severity != .ok }
            findings += problems
        }
        return findings
    }

    // MARK: VM

    public func vmFindings(name: String, snapshot: Snapshot, probeGuest: Bool) -> [VPhoneDiagnosticFinding] {
        func finding(
            _ category: VPhoneDiagnosticCategory, _ code: VPhoneDiagnosticCode, _ severity: VPhoneDiagnosticSeverity,
            _ message: String, evidence: [String: String] = [:], action: String? = nil
        ) -> VPhoneDiagnosticFinding {
            .init(category, code, severity, message, evidence: evidence, action: action, vm: name)
        }
        let url = library.url(forName: name)
        var isDirectory: ObjCBool = false
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return [finding(.input, .vmNotFound, .error, "no VM bundle with this name in the library",
                            evidence: ["library_root": library.root.path], action: "vphone-cli vm list")]
        }
        var findings: [VPhoneDiagnosticFinding] = []
        var bundle: VPhoneBundle?
        do {
            bundle = try VPhoneBundle.load(at: url)
        } catch {
            var reason = "\(error)"
            if case let VPhoneManifestError.loadFailed(_, underlying) = error {
                reason = (underlying as NSError).localizedDescription
            } else if case let VPhoneManifestError.parseFailed(_, underlying) = error {
                reason = "\(underlying)"
            }
            let missing = !FileManager.default.fileExists(atPath: url.appendingPathComponent("config.plist").path)
            findings.append(finding(.input, .vmManifestInvalid, .error,
                                    missing ? "config.plist is missing" : "config.plist cannot be loaded",
                                    evidence: missing ? [:] : ["reason": reason]))
        }
        if let bundle { findings.append(vmFiles(bundle, finding)) }

        let occupancy = vmOccupancy(url: url, snapshot: snapshot, finding)
        findings += occupancy.findings
        findings += patchState(url: url, name: name, lockHolder: occupancy.holderOperation, finding)
        if let bundle { findings.append(restoreState(bundle, finding)) }
        findings += createState(url: url, name: name, finding)
        if probeGuest { findings.append(guestRuntime(url: url, holder: occupancy.holderOperation, finding)) }
        return findings
    }

    typealias Make = (
        VPhoneDiagnosticCategory, VPhoneDiagnosticCode, VPhoneDiagnosticSeverity, String, [String: String], String?
    ) -> VPhoneDiagnosticFinding

    func vmFiles(
        _ bundle: VPhoneBundle,
        _ finding: Make
    ) -> VPhoneDiagnosticFinding {
        var required = [bundle.manifest.diskImage]
        if let roms = bundle.manifest.romImages { required += [roms.avpBooter, roms.avpSEPBooter] }
        let missing = required.filter { !FileManager.default.fileExists(atPath: bundle.manifest.resolve(path: $0, in: bundle.url).path) }
        var evidence = ["disk_image": bundle.manifest.diskImage, "disk_logical_bytes": "\(bundle.diskSizeBytes)"]
        guard missing.isEmpty else {
            evidence["missing"] = missing.joined(separator: ", ")
            return finding(.input, .vmFiles, .error, "files named by config.plist are missing", evidence,
                           "recreate the VM (vphone-cli vm create) or restore a backup")
        }
        return finding(.input, .vmFiles, .ok, "disk image and ROMs named by config.plist are present", evidence, nil)
    }

    struct Occupancy {
        var findings: [VPhoneDiagnosticFinding]
        /// Operation of a live lock holder, "unknown" when held without a live record, nil when free.
        var holderOperation: String?
    }

    func vmOccupancy(
        url: URL, snapshot: Snapshot,
        _ finding: Make
    ) -> Occupancy {
        var findings: [VPhoneDiagnosticFinding] = []
        let held = probes.bundleLockHeld(url)
        let record = VPhoneVMRuntimeState.read(in: url)
        let bootPIDs = snapshot.processList.map { Self.bootPIDs($0, bundleURL: url) }
        var evidence: [String: String] = ["bundle_lock_held": "\(held)"]
        var recordAlive = false
        if let record {
            let identity = probes.processIdentity(record.pid)
            recordAlive = identity.map { !$0.isZombie } ?? false
            evidence["record_operation"] = record.operation
            evidence["record_pid"] = "\(record.pid)"
            evidence["record_started_at"] = ISO8601DateFormatter().string(from: record.startedAt)
            evidence["record_pid_alive"] = "\(recordAlive)"
        } else {
            evidence["record"] = FileManager.default.fileExists(atPath: url.appendingPathComponent(VPhoneVMRuntimeState.filename).path)
                ? "unreadable" : "absent"
        }
        if let bootPIDs { evidence["boot_pids"] = bootPIDs.map(String.init).joined(separator: ",") }

        var holder: String?
        if held {
            if let record, recordAlive {
                holder = record.operation
                if record.isBootOperation {
                    if let bootPIDs { evidence["record_pid_is_boot_process"] = "\(bootPIDs.contains(record.pid))" }
                    findings.append(finding(.occupancy, .vmRunning, .ok,
                                            record.isDFUOperation ? "VM is running in DFU mode" : "VM is running", evidence, nil))
                } else {
                    findings.append(finding(.occupancy, .vmOperationInProgress, .warning,
                                            "operation \"\(record.operation)\" holds the bundle; other operations will be refused until it ends",
                                            evidence, nil))
                }
            } else {
                holder = "unknown"
                findings.append(finding(.occupancy, .vmLockHolderUnknown, .warning,
                                        "the bundle lock is held but the runtime record does not name a live process",
                                        evidence, "ps -axo pid,command | grep vphone"))
            }
        } else if let bootPIDs, !bootPIDs.isEmpty {
            findings.append(finding(.occupancy, .vmBootProcessWithoutLock, .error,
                                    "a vphone-cli process uses this config.plist but does not hold the bundle lock",
                                    evidence, "stop that process before any offline operation"))
        } else {
            let message = record == nil ? "VM is not running and no operation holds it"
                : "VM is not running; the runtime record is from an earlier holder and is diagnostic only"
            findings.append(finding(.occupancy, .vmIdle, .ok, message, evidence, nil))
        }

        if let images = snapshot.attachedImages {
            let prefixes = [url.standardizedFileURL.path + "/", url.resolvingSymlinksInPath().standardizedFileURL.path + "/"]
            let inside = images.filter { image in prefixes.contains { image.hasPrefix($0) } }
            if !inside.isEmpty {
                findings.append(finding(.occupancy, .attachedImages, held ? .ok : .warning,
                                        held ? "disk images inside the bundle are attached while an operation holds it"
                                            : "disk images inside the bundle are attached although nothing holds the bundle",
                                        ["images": inside.joined(separator: ", ")],
                                        held ? nil : "hdiutil detach <device> after confirming no CFW install is running"))
            }
        } else {
            findings.append(finding(.occupancy, .attachedImages, .unknown, "hdiutil info could not be read", [:], nil))
        }

        let residue = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasPrefix(".cfw_mount.") }.sorted()
        if !residue.isEmpty {
            findings.append(finding(.occupancy, .cfwMountResidue, held ? .ok : .warning,
                                    held ? "CFW mount directories exist while an operation holds the bundle"
                                        : "CFW mount directories remain from an earlier install",
                                    ["directories": residue.joined(separator: ", ")],
                                    held ? nil : "check `mount` and `hdiutil info`; detach anything mounted there, then remove the empty directories"))
        }
        return Occupancy(findings: findings, holderOperation: holder)
    }

    func patchState(
        url: URL, name: String, lockHolder: String?,
        _ finding: Make
    ) -> [VPhoneDiagnosticFinding] {
        var findings: [VPhoneDiagnosticFinding] = []
        if let requirement = VPhoneCreateRunner.firmwareTransactionRequirement(bundleURL: url) {
            var evidence = ["detail": requirement.detail]
            if let journal = Self.journal(url.appendingPathComponent(".firmware-transaction")) {
                evidence["phase"] = journal["phase"] as? String ?? "unknown"
                if let failure = journal["failure"] as? String { evidence["failure"] = failure }
                if let variant = (journal["options"] as? [String: Any])?["variant"] as? String { evidence["variant"] = variant }
            }
            if lockHolder == VPhoneVMOperation.fwPatch {
                findings.append(finding(.patch, .firmwareTransactionPending, .ok,
                                        "a firmware patch is in progress", evidence, nil))
            } else {
                findings.append(finding(.patch, .firmwareTransactionPending, .error,
                                        "an uncommitted firmware transaction blocks every other bundle operation",
                                        evidence, "vphone-cli fw patch \(name) --recover"))
            }
        }
        let history = url.appendingPathComponent(".firmware-history")
        let archives = ((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasPrefix("initializing-") }
        if !archives.isEmpty {
            let dated = archives.map { archive -> (String, Date) in
                let journal = history.appendingPathComponent(archive).appendingPathComponent("journal.json")
                let date = (try? FileManager.default.attributesOfItem(atPath: journal.path)[.modificationDate] as? Date) ?? .distantPast
                return (archive, date)
            }
            let latest = dated.max { $0.1 < $1.1 }!
            var evidence = ["archives": "\(archives.count)", "latest": latest.0]
            if let journal = Self.journal(history.appendingPathComponent(latest.0)) {
                let phase = journal["phase"] as? String ?? "unknown"
                evidence["latest_phase"] = phase
                if let variant = (journal["options"] as? [String: Any])?["variant"] as? String { evidence["latest_variant"] = variant }
                if phase == "committed" {
                    findings.append(finding(.patch, .firmwareHistory, .ok, "last firmware transaction is committed", evidence, nil))
                } else {
                    findings.append(finding(.patch, .firmwareHistory, .warning,
                                            "the latest archived firmware transaction is not committed (recovered or rolled back)", evidence, nil))
                }
            } else {
                findings.append(finding(.patch, .firmwareHistory, .warning, "the latest firmware transaction journal is unreadable", evidence, nil))
            }
        }
        return findings
    }

    static func journal(_ directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("journal.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func restoreState(
        _ bundle: VPhoneBundle,
        _ finding: Make
    ) -> VPhoneDiagnosticFinding {
        var evidence = [
            "machine_identifier": bundle.manifest.machineIdentifier.isEmpty ? "absent" : "present",
            "restore_info_file": FileManager.default.fileExists(atPath: VPhoneRestoreInfo.url(forBundle: bundle).path) ? "present" : "absent",
        ]
        guard let info = VPhoneRestoreInfo.load(fromBundle: bundle) else {
            return finding(.restore, .restoreState, .warning,
                           "no restored iOS/cloudOS versions are recorded or derivable; the VM may not have completed a restore",
                           evidence, "vphone-cli vm create-status \(bundle.name)")
        }
        evidence["ios"] = "\(info.ios.version) (\(info.ios.build))"
        evidence["cloudos"] = "\(info.cloudOS.version) (\(info.cloudOS.build))"
        evidence["variant"] = info.variant ?? "unrecorded"
        if let device = info.device { evidence["device"] = device }
        guard !bundle.manifest.machineIdentifier.isEmpty else {
            return finding(.restore, .restoreState, .warning,
                           "versions are known but config.plist has no machineIdentifier; no DFU boot has completed", evidence, nil)
        }
        return finding(.restore, .restoreState, .ok, "restore state recorded", evidence, nil)
    }

    /// Stage → the category a problem in that stage belongs to.
    public static func category(for stage: VPhoneCreateStage) -> VPhoneDiagnosticCategory {
        switch stage {
        case .prepare: .input
        case .patch, .cfw: .patch
        case .restore: .restore
        case .firstBoot, .jbFinalize, .verification: .guestRuntime
        }
    }

    func createState(
        url: URL, name: String,
        _ finding: Make
    ) -> [VPhoneDiagnosticFinding] {
        let checkpoint: VPhoneCreateCheckpoint
        do {
            checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: url).checkpoint
        } catch VPhoneCreateCheckpointError.missing {
            return [finding(.input, .createCheckpointAbsent, .ok,
                            "no create checkpoint (VM not made by vm create, or made before checkpoints existed)", [:], nil)]
        } catch {
            return [finding(.input, .createCheckpointInvalid, .error, "the create checkpoint is corrupt or unsupported",
                            ["reason": "\(error)"], "vphone-cli vm create-status \(name)")]
        }
        var evidence = ["overall_status": checkpoint.overallStatus.rawValue, "variant": checkpoint.effectiveOptions.variant,
                        "attempts": "\(checkpoint.attempts.count)"]
        if let next = checkpoint.nextStage { evidence["next_stage"] = next.rawValue }
        // A live run owns the checkpoint: its `running` stage is progress, not an interruption.
        if probes.createRunLockHeld(url) {
            if let running = checkpoint.stages.first(where: { $0.status == .running }) { evidence["running_stage"] = running.stage.rawValue }
            return [finding(.occupancy, .createRunInProgress, .ok,
                            "a vm create/resume run holds the create checkpoint now", evidence, nil)]
        }
        let resume = "vphone-cli vm create --resume \(name)"
        switch checkpoint.overallStatus {
        case .succeeded:
            return [finding(.guestRuntime, .createSucceeded, .ok, "vm create finished and every stage verified", evidence, nil)]
        case .recoveryRequired:
            let requirement = checkpoint.recoveryRequired!
            evidence["recovery_kind"] = requirement.kind
            evidence["detail"] = requirement.detail
            if let stage = requirement.stage { evidence["stage"] = stage.rawValue }
            let category: VPhoneDiagnosticCategory = switch requirement.kind {
            case "firmware_transaction": .patch
            case "live_state": .occupancy
            default: requirement.stage.map(Self.category(for:)) ?? .input
            }
            return [finding(category, .createRecoveryRequired, .error, "vm create stopped and needs recovery before resuming",
                            evidence, requirement.action)]
        case .failed, .cancelled, .interrupted:
            let status: VPhoneCreateStageStatus = checkpoint.overallStatus == .failed ? .failed
                : checkpoint.overallStatus == .cancelled ? .cancelled : .running
            let record = checkpoint.stages.first { $0.status == status }!
            evidence["stage"] = record.stage.rawValue
            if let error = record.error { evidence["last_error"] = error }
            if let reason = record.reason { evidence["reason"] = reason }
            let category = Self.category(for: record.stage)
            switch status {
            case .failed:
                return [finding(category, .createStageFailed, .error, "vm create failed at stage \(record.stage.rawValue)", evidence, resume)]
            case .cancelled:
                return [finding(category, .createCancelled, .warning, "vm create was cancelled at stage \(record.stage.rawValue)", evidence, resume)]
            default:
                return [finding(category, .createInterrupted, .warning,
                                "vm create stopped while stage \(record.stage.rawValue) was running", evidence, resume)]
            }
        case .completedUnverified:
            let unverified = checkpoint.stages.filter { $0.status == .unverified }
            evidence["unverified_stages"] = unverified.map(\.stage.rawValue).joined(separator: ", ")
            for record in unverified { if let reason = record.reason { evidence["reason_\(record.stage.rawValue)"] = reason } }
            return [finding(Self.category(for: unverified.first!.stage), .createCompletedUnverified, .warning,
                            "vm create finished, but some stages have no host-side evidence of success", evidence, nil)]
        case .incomplete:
            let stage = checkpoint.nextStage ?? .prepare
            return [finding(Self.category(for: stage), .createIncomplete, .warning,
                            "vm create has not finished; next stage is \(stage.rawValue)", evidence, resume)]
        }
    }

    func guestRuntime(
        url: URL, holder: String?,
        _ finding: Make
    ) -> VPhoneDiagnosticFinding {
        guard holder == VPhoneVMOperation.boot else {
            let message = holder == VPhoneVMOperation.dfu ? "VM is in DFU mode; no guest control channel exists"
                : "VM is not running; guest runtime not checked"
            return finding(.guestRuntime, .guestNotRunning, .ok, message, [:], nil)
        }
        let socket = url.appendingPathComponent("vphone.sock").path
        switch probes.hostControlCapabilities(socket) {
        case .missing:
            return finding(.guestRuntime, .hostControlSocketMissing, .error,
                           "VM is running but its host control socket is missing", ["socket": socket], nil)
        case .notSocket:
            return finding(.guestRuntime, .hostControlUnreachable, .error,
                           "host control path exists but is not a socket", ["socket": socket], nil)
        case let .connectFailed(reason), let .noResponse(reason):
            return finding(.guestRuntime, .hostControlUnreachable, .error,
                           "host control socket did not answer a capabilities request", ["socket": socket, "reason": reason], nil)
        case let .rejected(reason):
            return finding(.guestRuntime, .hostControlCapabilitiesUnavailable, .unknown,
                           "host control answers but rejected the capabilities request (a VM started from an older build?); guest connection not determined",
                           ["socket": socket, "reason": reason], nil)
        case let .capabilities(connected, screen, version, count):
            var evidence = ["socket": socket, "guest_capability_count": "\(count)"]
            if let screen { evidence["screen_available"] = "\(screen)" }
            if let version { evidence["protocol_version"] = "\(version)" }
            guard connected else {
                return finding(.guestRuntime, .guestDisconnected, .warning,
                               "host control answers, but vphoned in the guest is not connected (still booting, not installed, or stopped)",
                               evidence, nil)
            }
            return finding(.guestRuntime, .guestConnected, .ok, "vphoned in the guest is connected", evidence, nil)
        }
    }
}
