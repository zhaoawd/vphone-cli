// PatchIdentifier.swift — Stable per-method patch identifier (C2).

import Foundation

/// A stable, method-level patch identifier: `<component>.<patcher>.<method>`.
///
/// - `component` is the pipeline component name (`avpbooter`, `ibss`, `ibec`, `llb`,
///   `txm`, `kernelcache`, `devicetree`, `filesystem`, `manifest`) — NOT the
///   patcher's inconsistent `component` string.
/// - `patcher` is the patcher type's simple name (`AVPBooterPatcher`, `IBootJBPatcher`).
/// - `method` is the Swift method name and matches `methods[].name` in
///   `research/firmware_compatibility.json` (the C1 alignment key).
///
/// Encodes to / decodes from a single dotted string so report JSON stays flat and
/// the `--ablate` CLI value is the same string.
public struct PatchID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let component: String
    public let patcher: String
    public let method: String

    public init(component: String, patcher: String, method: String) {
        self.component = component
        self.patcher = patcher
        self.method = method
    }

    public var description: String { "\(component).\(patcher).\(method)" }

    /// Component-level ablation target (`avpbooter`).
    public var componentTarget: String { component }
    /// Patcher-level ablation target (`avpbooter.AVPBooterPatcher`).
    public var patcherTarget: String { "\(component).\(patcher)" }

    /// Whether an `--ablate` value matches this id at component, patcher, or full granularity.
    public func matchesAblation(_ value: String) -> Bool {
        value == componentTarget || value == patcherTarget || value == description
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let parts = raw.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "PatchID must be '<component>.<patcher>.<method>', got '\(raw)'"
            )
        }
        component = String(parts[0])
        patcher = String(parts[1])
        method = String(parts[2])
    }
}
