// PatchDeclaration.swift — Declaration-layer model for the five-variant plan (T10/T11).
//
// A declaration is the stable selection unit that sits on top of a local firmware
// variant. Its `id` is the upstream 2.2.3 declaration id where one exists (from the
// T09 mapping), or a `{component}-{effect}-{name}` local id where the local step has
// no upstream declaration. The local `PatchRule` version conditions stay authoritative
// (design decision 2); `upstreamApplicability` is recorded for cross-reference only.
//
// Coverage says who writes the patch:
//   - `.swift`  — a local Swift FirmwarePatcher step (boot chain / kernel / DeviceTree /
//                 less filesystem+manifest). These are the strict-gate scope this round.
//   - `.guestStep` — a guest-side Python/zsh CFW step (dyld-* / system-* / preboot-*).
//                 Declaration-only this round: listed and consistency-checked, but its
//                 execution path is not gated (design decision 5).
//   - `.notImplemented` — declared upstream but with no local implementation
//                 (`dyld-exp-mis_trust_auth`; libmisfix is T18). Selecting it is refused
//                 (design decision 4).

import Foundation

/// One selectable patch as the declaration layer sees it.
public struct PatchDeclaration: Sendable, Hashable, Codable {
    public enum Coverage: String, Sendable, Codable, Hashable {
        /// Written by a local Swift FirmwarePatcher step (strict-gate scope).
        case swift
        /// Written by a guest-side Python/zsh CFW step (declaration-only this round).
        case guestStep = "guest"
        /// Declared upstream, not implemented locally.
        case notImplemented
    }

    public enum OptIn: String, Sendable, Codable, Hashable {
        /// Runs whenever its variant and version condition allow.
        case none
        /// Requires the `--frida` opt-in in addition to variant and version.
        case frida
    }

    /// Stable declaration id (upstream id, or `{component}-{effect}-{name}` local id).
    public let id: String
    /// One-line label.
    public let title: String
    /// Who writes the patch.
    public let coverage: Coverage
    /// Local Swift step `PatchID.description` values this declaration authorizes.
    /// A record emitted by one of these steps is attributed to this declaration.
    /// Empty for `.guestStep` / `.notImplemented`. One step may be bound by more than
    /// one declaration when upstream splits a single local method into several ids
    /// (`patchApfsMount`, `patchSandbox`).
    public let swiftSteps: [String]
    /// Variants whose component list includes this declaration's step(s). Gate/version
    /// independent (a conditional step is a member even where its rule is false).
    public let variants: Set<String>
    /// Extra opt-in the declaration needs beyond variant + version.
    public let optIn: OptIn
    /// Whether the guest does not boot without this patch (upstream `bootEssential`).
    public let required: Bool
    /// The local `PatchRule` version condition (authoritative). nil for guest /
    /// notImplemented (their version conditions live in the guest scripts, out of scope).
    public let versionRule: PatchRule?
    /// The upstream declaration id(s) this maps to (empty for a local_only declaration).
    public let upstreamIDs: [String]
    /// The upstream `VPhonePatchApplicability`, recorded for cross-reference only.
    public let upstreamApplicability: String
    /// Declarations this one needs enabled (empty in the real catalog; the resolver
    /// enforces it so the dependency-rejection path is a real mechanism).
    public let requires: [String]
    /// Declarations this one cannot sit with (empty in the real catalog).
    public let conflicts: [String]
    /// Declarations that must resolve before this one (empty in the real catalog).
    public let after: [String]

    public init(
        id: String,
        title: String,
        coverage: Coverage,
        swiftSteps: [String],
        variants: Set<String>,
        optIn: OptIn,
        required: Bool,
        versionRule: PatchRule?,
        upstreamIDs: [String],
        upstreamApplicability: String,
        requires: [String],
        conflicts: [String],
        after: [String]
    ) {
        self.id = id
        self.title = title
        self.coverage = coverage
        self.swiftSteps = swiftSteps
        self.variants = variants
        self.optIn = optIn
        self.required = required
        self.versionRule = versionRule
        self.upstreamIDs = upstreamIDs
        self.upstreamApplicability = upstreamApplicability
        self.requires = requires
        self.conflicts = conflicts
        self.after = after
    }
}
