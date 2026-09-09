@testable import VPhoneCore
import Foundation
import Testing

/// Cross-checks research/firmware_compatibility.json against the in-code firmware
/// catalog so the manifest cannot drift from `VPhoneFirmwareCatalog`.
///
/// VPhoneCoreTests only links VPhoneCore, so `FirmwarePipeline.Variant` (in the
/// FirmwarePatcher target) is not importable here; the variant set is checked
/// against the canonical literal below, which must mirror
/// `FirmwarePipeline.Variant` / `PatchFirmwareCLI.VariantOption`.
struct FirmwareCompatibilityManifestTests {
    /// Canonical variant list — mirror of `FirmwarePipeline.Variant` (not importable in this target).
    static let canonicalVariants: Set<String> = ["less", "regular", "dev", "jb", "exp"]

    static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("research/firmware_compatibility.json").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate research/firmware_compatibility.json above \(#filePath)")
    }

    static func manifest() throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("research/firmware_compatibility.json")
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// (version, build) parsed from an IPSW URL like `..._26.1_23B85_Restore.ipsw`.
    static func parse(iosURL: String) -> (version: String, build: String)? {
        guard let file = iosURL.split(separator: "/").last else { return nil }
        let parts = file.split(separator: "_")
        // iPhone17,3 / <version> / <build> / Restore.ipsw
        guard parts.count >= 4 else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    @Test func catalogPairingsMatchManifest() throws {
        let m = try Self.manifest()
        let ios = (m["firmware"] as! [String: Any])["ios"] as! [[String: Any]]

        // Manifest side: (version, build, cloudos friendly) for source == "catalog".
        var manifestSet = Set<[String]>()
        for e in ios where (e["source"] as? String) == "catalog" {
            manifestSet.insert([
                e["version"] as! String,
                e["build"] as! String,
                e["cloudos_name"] as! String,
            ])
        }

        // Code side: derive the same tuple from the in-code catalog.
        var codeSet = Set<[String]>()
        for p in VPhoneFirmwareCatalog.pairings {
            let parsed = Self.parse(iosURL: p.iosURL)
            #expect(parsed != nil, "unparseable IPSW URL: \(p.iosURL)")
            guard let parsed else { continue }
            codeSet.insert([parsed.version, parsed.build, p.cloudosName])
        }

        let onlyInCode = codeSet.subtracting(manifestSet)
        let onlyInManifest = manifestSet.subtracting(codeSet)
        #expect(manifestSet == codeSet,
                "catalog↔manifest drift; only-in-code=\(onlyInCode), only-in-manifest=\(onlyInManifest)")
    }

    @Test func variantsMatchCanonical() throws {
        let m = try Self.manifest()
        let dims = m["dimensions"] as! [String: Any]
        let variants = Set(dims["variants"] as! [String])
        #expect(variants == Self.canonicalVariants)

        // patch_configurations must have exactly one entry per variant.
        let configs = m["patch_configurations"] as! [[String: Any]]
        let cfgVariants = configs.map { $0["variant"] as! String }
        #expect(Set(cfgVariants) == Self.canonicalVariants)
        #expect(cfgVariants.count == Self.canonicalVariants.count)
    }
}
