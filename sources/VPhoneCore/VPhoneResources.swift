import Foundation

// MARK: - VPhoneResourcesError

public enum VPhoneResourcesError: Error, Equatable {
    case pythonNotFound(String)
    case venvBootstrapFailed(String)
}

// MARK: - VPhoneResources

public struct VPhoneResources: Sendable {
    public let base: URL

    private let environmentOverride: [String: String]?
    private var environment: [String: String] {
        environmentOverride ?? ProcessInfo.processInfo.environment
    }

    public init(base: URL) {
        self.base = base
        environmentOverride = nil
    }

    // Deterministic configuration for tests; normal callers keep live environment reads.
    init(base: URL, environment: [String: String]) {
        self.base = base
        environmentOverride = environment
    }

    // MARK: - Resolution

    /// The running executable, resolved reliably. `CommandLine.arguments[0]` is
    /// NOT reliable — under a PATH/symlink launch (e.g. a Homebrew symlink) it's
    /// a bare name that `URL(fileURLWithPath:)` resolves against the CWD, so the
    /// binary/base end up under `$HOME`. `Bundle.main.executableURL` is the
    /// kernel-provided executable path, correct regardless of how the process
    /// was invoked; resolve symlinks so a brew symlink lands on the real binary
    /// inside the .app.
    public static func runningExecutable() -> URL {
        if let exe = Bundle.main.executableURL { return exe.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    public static func resolve(executablePath: String? = nil) -> VPhoneResources {
        let exe = executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            ?? runningExecutable()
        let macos = exe.deletingLastPathComponent()             // …/Contents/MacOS
        if macos.lastPathComponent == "MacOS",
           macos.deletingLastPathComponent().lastPathComponent == "Contents" {
            return VPhoneResources(base: macos.deletingLastPathComponent()
                .appendingPathComponent("Resources"))            // …/Contents/Resources
        }
        var dir = macos
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts").path) {
                return VPhoneResources(base: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
        return VPhoneResources(base: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    // MARK: - Assets

    public var scriptsDir: URL { base.appendingPathComponent("scripts") }
    public var patchersDir: URL { scriptsDir.appendingPathComponent("patchers") }
    public var resourceArchivesDir: URL { scriptsDir.appendingPathComponent("resources") }
    public var fwPrepareScript: URL { scriptsDir.appendingPathComponent("fw_prepare.sh") }
    public var cfwInstallHostScript: URL { scriptsDir.appendingPathComponent("cfw_install_host.sh") }
    public var preflightScript: URL { scriptsDir.appendingPathComponent("boot_host_preflight.sh") }
    public var pmd3Bridge: URL { scriptsDir.appendingPathComponent("pymobiledevice3_bridge.py") }
    public var cfwPy: URL { patchersDir.appendingPathComponent("cfw.py") }
    public var apfsSnapRename: URL { base.appendingPathComponent("tools/apfs_snap_rename.py") }
    public var signcert: URL { scriptsDir.appendingPathComponent("vphoned/signcert.p12") }

    /// Files the `resources` probe requires.
    public var coreRuntimeResources: [URL] { [fwPrepareScript, cfwPy, signcert, requirementsFile] }

    /// Every file a full create (prepare, patch, restore, CFW, boot) reads from
    /// the resource base. `scripts/check_bundle.py` checks the complete app list.
    public var runtimeResources: [URL] {
        coreRuntimeResources + [
            cfwInstallHostScript, preflightScript, pmd3Bridge, apfsSnapRename, pythonRuntimeCheckScript,
            scriptsDir.appendingPathComponent("python_environment.py"),
            resourceArchivesDir.appendingPathComponent("cfw_input.tar.zst"),
            resourceArchivesDir.appendingPathComponent("cfw_jb_input.tar.zst"),
            toolsBinDir.appendingPathComponent("trustcache"),
            toolsBinDir.appendingPathComponent("insert_dylib"),
            vphoned,
        ]
    }

    public var vphoned: URL {
        let bundled = base.appendingPathComponent("vphoned.signed")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Dev fallback: build.sh stages the signed daemon under .build (a
        // gitignored build-output dir) rather than cluttering the repo root.
        return base.appendingPathComponent(".build/vphoned.signed")
    }

    // MARK: - Cache dirs

    /// The per-user data root: `$VPHONE_ROOT` when set, else `~/.vphone`. Both
    /// `VPhoneResources` (ipsws/tools/debs/venv) and `VPhoneLibrary` (VMs)
    /// derive from this so one variable redirects everything vphone-cli creates.
    public static func userDataRoot() -> URL {
        userDataRoot(environment: ProcessInfo.processInfo.environment)
    }

    static func userDataRoot(environment: [String: String]) -> URL {
        if let root = environment["VPHONE_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone")
    }

    public var userCacheDir: URL { Self.userDataRoot(environment: environment) }
    public var ipswCacheDir: URL { userCacheDir.appendingPathComponent("ipsws") }
    public var sealVolumeCacheDir: URL { userCacheDir.appendingPathComponent("tools") }
    public var debsCacheDir: URL { userCacheDir.appendingPathComponent("debs") }
    public var toolsBinDir: URL { base.appendingPathComponent(".tools/bin") }

    // MARK: - Python

    public var requirementsFile: URL { base.appendingPathComponent("requirements.txt") }

    public var managedVenvDir: URL {
        if let dir = environment["VPHONE_VENV_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return userCacheDir.appendingPathComponent("venv")
    }

    /// Script and Swift callers use the same capabilities and platform lock.
    func pythonIsUsable(_ python: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        return (try? VPhoneProcessRunner.runCapturing(python,
            [pythonRuntimeCheckScript.path, "--locked", "--json"],
            env: environment))?.succeeded == true
    }

    public enum PythonSource: String, Sendable {
        /// `VPHONE_PYTHON`; when set it is the only candidate.
        case environmentOverride = "VPHONE_PYTHON"
        case developmentVenv = "dev_venv"
        case managedVenv = "managed_venv"
    }

    /// Interpreters `pythonExecutable()` tries, in order, before bootstrapping.
    public var pythonCandidates: [(source: PythonSource, url: URL)] {
        if let override = environment["VPHONE_PYTHON"], !override.isEmpty {
            return [(.environmentOverride, URL(fileURLWithPath: override))]
        }
        return [(.developmentVenv, base.appendingPathComponent(".venv/bin/python3")),
                (.managedVenv, managedVenvDir.appendingPathComponent("bin/python3"))]
    }

    public var pythonRuntimeCheckScript: URL { scriptsDir.appendingPathComponent("check_python_runtime.py") }

    public func pythonExecutable(forceManaged: Bool = false) throws -> URL {
        if !forceManaged {
            for candidate in pythonCandidates {
                if pythonIsUsable(candidate.url) { return candidate.url }
                if candidate.source == .environmentOverride {
                    throw VPhoneResourcesError.pythonNotFound(
                        "VPHONE_PYTHON failed locked runtime verification: \(candidate.url.path)")
                }
            }
        }
        return try bootstrapManagedVenv(force: forceManaged)
    }

    /// The manager builds a new generation and only publishes it after verification.
    /// A failed install leaves the previously selected environment available.
    private func bootstrapManagedVenv(force: Bool) throws -> URL {
        var errors: [String] = []
        for host in candidateHostPythons() {
            var args = [scriptsDir.appendingPathComponent("python_environment.py").path,
                        "--base", base.path, "--venv", managedVenvDir.path]
            if force { args.append("--force") }
            do {
                let result = try VPhoneProcessRunner.runCapturing(host, args, env: environment)
                if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
                let python = managedVenvDir.appendingPathComponent("bin/python3")
                if result.succeeded, pythonIsUsable(python) { return python }
                errors.append("\(host.path): \(result.stderr)")
            } catch {
                errors.append("\(host.path): \(error)")
            }
        }
        throw VPhoneResourcesError.venvBootstrapFailed(
            "No host Python could provision the locked environment. " + errors.joined(separator: "\n"))
    }

    private func candidateHostPythons() -> [URL] {
        if let explicit = environment["VPHONE_HOST_PYTHON"], !explicit.isEmpty {
            return [URL(fileURLWithPath: explicit)]
        }
        var paths: [String] = []
        for name in ["python3.13", "python3.14"] {
            if let result = try? VPhoneProcessRunner.runCapturing(
                URL(fileURLWithPath: "/usr/bin/which"), [name], env: environment), result.succeeded {
                paths.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            paths.append("/opt/homebrew/bin/" + name)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
