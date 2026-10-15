import Foundation
import FirmwarePatcher
import VPhoneBundleStore
import VPhoneCore

/// Live current-Bundle qualification for online library writes. This scope does
/// not publish a component receipt or change any launchpad origin field.
@MainActor
enum VPhoneGuestEnvironmentSource {
    struct Scope {
        let context: [String: String]
        let stage: URL
        let manifest: URL
        let verify: () throws -> Void
        fileprivate init(context: [String: String], stage: URL, manifest: URL, verify: @escaping () throws -> Void) {
            self.context = context; self.stage = stage; self.manifest = manifest; self.verify = verify
        }
    }

    static func withCurrentBundle<T>(runtime: VPhoneVMLock, requestedStage: String?,
        body: @MainActor (Scope) async throws -> T) async throws -> T {
        let machine = URL(fileURLWithPath: runtime.state.bundlePath)
        guard let binding = try VPhoneMachineBinding.snapshot(machine) else {
            throw VPhoneGuestEnvironmentRefusal("source_unqualified", "Online update requires a verified current Core Bundle binding")
        }
        return try await VPhoneCoreBundleStore().withRevalidatedExecutableAsync(version: binding.binding.bundle, executable: .vm) { executable, verify in
            try await withVerifiedInput(runtime: runtime, version: binding.binding.bundle, executable: executable,
                effectiveExecutable: VPhoneResources.runningExecutable(), requestedStage: requestedStage, verifyBundle: verify, body: body)
        }
    }

    /// The verifier seam substitutes code-signature verification in file tests;
    /// runtime ownership, frozen plan, paths and actual bytes remain mandatory.
    static func withVerifiedInput<T>(runtime: VPhoneVMLock, version: String, executable: URL,
        effectiveExecutable: URL, requestedStage: String?, verifyBundle: @escaping @MainActor () throws -> Void,
        body: @MainActor (Scope) async throws -> T) async throws -> T {
        let machine = URL(fileURLWithPath: runtime.state.bundlePath)
        guard runtime.state.operation == VPhoneVMOperation.boot,
              VPhoneCoreBundleVersion.supportsTargetFeatures(version),
              executable.standardizedFileURL == effectiveExecutable.standardizedFileURL,
              executable == executable.resolvingSymlinksInPath(),
              let binding = try VPhoneMachineBinding.snapshot(machine), binding.binding.bundle == version,
              case let .ready(desired) = try FirmwareDesiredPlanStore.read(in: machine),
              desired.plan.variant == "regular", desired.plan.gates.guestEnvironmentV2 == true,
              desired.plan.guestUncovered.contains(where: { $0.id == "system-launchdaemons-boot-environment" && $0.recordRules != nil }) else {
            throw VPhoneGuestEnvironmentRefusal("source_unqualified", "Online libraries require the current Bundle and a verified frozen regular/v2 plan")
        }
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let stage = resources.appendingPathComponent(".build/guest-components-v2/stage")
        if let requestedStage, URL(fileURLWithPath: requestedStage).standardizedFileURL != stage.standardizedFileURL {
            throw VPhoneGuestEnvironmentRefusal("source_unqualified", "Candidates must belong to the running verified Core Bundle")
        }
        let manifestURL = resources.appendingPathComponent("scripts/guest_environment.json")
        let manifest = try VPhoneGuestEnvironmentManifest.load(manifestURL)
        let candidates = try VPhoneGuestEnvironmentCandidates.verify(stage: stage, manifest: manifest)
        let daemon = resources.appendingPathComponent(".build/daemon-api-v2/candidate-v2/vphoned")
        func sourceDigest(_ url: URL) throws -> String {
            var info = stat()
            guard url == url.resolvingSymlinksInPath(),
                  lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let data = FileManager.default.contents(atPath: url.path) else {
                throw VPhoneGuestEnvironmentRefusal("source_unqualified", "Current Bundle source is absent or linked")
            }
            return VPhoneGuestEnvironmentCandidates.sha256(data)
        }
        let daemonHash = try sourceDigest(daemon), executableHash = try sourceDigest(executable)
        var active = true
        defer { active = false }
        let recheck: () throws -> Void = {
            try Task.checkCancellation()
            guard active else { throw VPhoneGuestEnvironmentRefusal("source_expired", "Online source scope expired") }
            try verifyBundle()
            guard runtime.state.instanceID == VPhoneVMRuntimeState.read(in: machine)?.instanceID,
                  try VPhoneMachineBinding.snapshot(machine) == binding,
                  case let .ready(current) = try FirmwareDesiredPlanStore.read(in: machine), current == desired,
                  try sourceDigest(executable) == executableHash, try sourceDigest(daemon) == daemonHash,
                  try VPhoneGuestEnvironmentManifest.load(manifestURL) == manifest,
                  try VPhoneGuestEnvironmentCandidates.verify(stage: stage, manifest: manifest) == candidates else {
                throw VPhoneGuestEnvironmentRefusal("source_changed", "Current Bundle, runtime or frozen plan changed during online operation")
            }
        }
        try recheck()
        let scope = Scope(context: ["mode": "regular-v2", "plan_sha256": desired.planSHA256,
            "desired_sha256": try desired.sha256, "firmware_generation": desired.generationID,
            "bundle_version": version, "executable_sha256": executableHash,
            "daemon_sha256": daemonHash, "vm_instance": runtime.state.instanceID],
            stage: stage, manifest: manifestURL, verify: recheck)
        let result = try await body(scope)
        try recheck()
        return result
    }
}
