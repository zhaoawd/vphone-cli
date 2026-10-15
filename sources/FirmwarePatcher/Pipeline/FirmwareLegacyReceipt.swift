import Foundation
import Darwin
import VPhoneCore

/// Read-only compatibility with fixed upstream 2d21d21. Imported statements are
/// retained as data; only a fresh qualified transaction can establish effects.
public enum FirmwareLegacyReceipt {
    public enum Status: String, Sendable { case missing, corrupt, unsupported, imported }
    public struct Part: Sendable {
        public let patches: [String]
        public let writer: String
        public let bundleVersion: String?
        public let date: Date
        public let notApplicable: [String]
        public let layer: VPhoneMachineBinding.Layer?
    }
    public struct Plan: Sendable {
        public let presetIdentifier: String
        public let patchSets: [String]
        public let enabledPatches: [String]
        public let iOSBaseVersion: String?
        public let cloudOSVersion: String?
        public let parameters: [String: String]
    }
    public struct Import: Sendable {
        public let raw: Data?
        public let status: Status
        public let parts: [String: Part]
        public let plan: Plan?
        /// No legacy field can grant applied or verified status.
        public var verifiedDeclarations: [String] { [] }
    }

    public static func readReceipt(in directory: URL) throws -> Import {
        importReceipt(try read("PatchReceipt.plist", in: directory))
    }
    public static func readPlan(in directory: URL) throws -> Import {
        importPlan(try read("PatchPlan.plist", in: directory))
    }
    private static func read(_ name: String, in directory: URL) throws -> Data? {
        let file = directory.appendingPathComponent(name)
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try VPhoneCreateDigest.strictFileData(file, maximumBytes: 16 << 20)
    }

    public static func importReceipt(_ raw: Data?) -> Import {
        decode(raw) { fields in
            guard Set(fields.keys).isSubset(of: ["Parts"]) else { throw Format.unsupported }
            guard let parts = fields["Parts"] as? [String: Any] else { throw Format.corrupt }
            var result: [String: Part] = [:]
            for (key, value) in parts {
                guard let entry = value as? [String: Any] else { throw Format.corrupt }
                guard Set(entry.keys).isSubset(of: ["Patches", "Writer", "BundleVersion", "Date", "NotApplicable"]) else { throw Format.unsupported }
                guard let patches = entry["Patches"] as? [String], let writer = entry["Writer"] as? String,
                      let date = entry["Date"] as? Date else { throw Format.corrupt }
                result[key] = Part(patches: patches, writer: writer, bundleVersion: try optional(entry, "BundleVersion"),
                    date: date, notApplicable: try optional(entry, "NotApplicable") ?? [], layer: layer(for: key))
            }
            return (result, nil)
        }
    }

    public static func importPlan(_ raw: Data?) -> Import {
        decode(raw) { fields in
            guard Set(fields.keys).isSubset(of: ["Preset", "PatchSets", "EnabledPatches", "IOSBaseVersion", "CloudOSVersion", "Parameters"]) else { throw Format.unsupported }
            guard let preset = fields["Preset"] as? String else { throw Format.corrupt }
            return ([:], Plan(presetIdentifier: preset, patchSets: try optional(fields, "PatchSets") ?? [],
                enabledPatches: try optional(fields, "EnabledPatches") ?? [],
                iOSBaseVersion: try optional(fields, "IOSBaseVersion"), cloudOSVersion: try optional(fields, "CloudOSVersion"),
                parameters: try optional(fields, "Parameters") ?? [:]))
        }
    }

    /// Filesystem and Manifest describe restore artifacts, not one installed
    /// origin layer. Unknown keys remain unmapped with their original contents.
    static func layer(for part: String) -> VPhoneMachineBinding.Layer? {
        switch part {
        case "Guest": .guestEnvironment
        case "kernelcache": .kernel
        case "AVPBooter", "iBSS", "iBEC", "LLB", "TXM", "DeviceTree": .bootChain
        default: nil
        }
    }

    private enum Format: Error { case corrupt, unsupported }
    private static func optional<T>(_ fields: [String: Any], _ key: String) throws -> T? {
        guard let value = fields[key] else { return nil }
        guard let typed = value as? T else { throw Format.corrupt }
        return typed
    }
    private static func decode(_ raw: Data?, body: ([String: Any]) throws -> ([String: Part], Plan?)) -> Import {
        guard let raw else { return Import(raw: nil, status: .missing, parts: [:], plan: nil) }
        do {
            // The fixed writer emits XML. Reject duplicate XML dictionary keys
            // before Foundation's decoder can silently discard one value.
            if !raw.starts(with: Data("bplist".utf8)) {
                let validator = SelectionXMLValidator()
                let parser = XMLParser(data: raw)
                parser.shouldResolveExternalEntities = false
                parser.delegate = validator
                guard parser.parse(), validator.valid else { throw Format.corrupt }
            } else { throw Format.unsupported }
            guard let fields = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] else { throw Format.corrupt }
            let (parts, plan) = try body(fields)
            return Import(raw: raw, status: .imported, parts: parts, plan: plan)
        } catch Format.unsupported { return Import(raw: raw, status: .unsupported, parts: [:], plan: nil) }
        catch { return Import(raw: raw, status: .corrupt, parts: [:], plan: nil) }
    }
}
