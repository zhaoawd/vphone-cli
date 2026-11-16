import CryptoKit
import Foundation
import VPhonePatchKit

// Compiled with the working tree production TXM sources. Only private output files are written.
@main struct TXMProductionPolicyRegression {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = directory.appendingPathComponent("txm-reference.raw")
        let source = try Data(contentsOf: raw)
        let common: Set<String> = [
            "txm-boot-trustcache_bypass", "txm-cfw-get_task_allow",
            "txm-cfw-debugger_entitlement", "txm-boot-developer_mode_bypass",
            "txm-boot-selector24_bypass", "txm-boot-sel42_29",
        ]
        let declared = common.union([
            TXMDevPatcher.precheckAdmissionID, TXMDevPatcher.executableRemapID,
            "kernel-boot-amfi_trustcache",
        ])
        var results: [[String: Any]] = []
        var outcomes: [String: Data] = [:]
        for amfiBypass in [false, true] {
            for mode in ["remap", "precheck", "both", "neither"] {
                var enabled = common
                if amfiBypass { enabled.insert("kernel-boot-amfi_trustcache") }
                if mode == "remap" || mode == "both" { enabled.insert(TXMDevPatcher.executableRemapID) }
                if mode == "precheck" || mode == "both" { enabled.insert(TXMDevPatcher.precheckAdmissionID) }
                let patcher = TXMDevPatcher(data: source, verbose: false)
                patcher.gate = VPhonePatchGate(declared: declared, enabled: enabled)
                let records = try patcher.findAll()
                precondition(records.allSatisfy { !patcher.gate.isUndeclared(record: $0.patchID) })
                let precheck = records.filter { $0.patchID.hasPrefix(TXMDevPatcher.precheckAdmissionID + ".") }
                let remap = records.filter { $0.patchID.hasPrefix(TXMDevPatcher.executableRemapID + ".") }
                precondition(precheck.count == (mode == "precheck" || mode == "both" ? 4 : 0))
                precondition(remap.count == (mode == "remap" ? (amfiBypass ? 5 : 4) : 0))
                _ = try patcher.apply()
                outcomes[mode + String(amfiBypass)] = patcher.patchedData
                results.append([
                    "amfi_trustcache_bypass": amfiBypass, "mode": mode,
                    "precheck_records": precheck.count, "remap_records": remap.count,
                    "records": records.map { record in
                        ["identifier": record.patchID, "offset": record.fileOffset,
                         "after": record.patchedBytes.map { String(format: "%02x", $0) }.joined()] as [String: Any]
                    },
                ])
            }
            precondition(outcomes["both" + String(amfiBypass)] == outcomes["precheck" + String(amfiBypass)])
        }
        let baseline = "8b126bd60162f4c8bf58c8c205ce92515ca94a84fdb08782f370a07f11a042cf"
        for mode in ["precheckfalse", "prechecktrue"] {
            let digest = SHA256.hash(data: outcomes[mode]!).map { String(format: "%02x", $0) }.joined()
            precondition(digest == baseline, "Explicit precheck must preserve the measured c07ee974 baseline bytes")
        }
        for mode in ["remapfalse", "remaptrue", "prechecktrue"] {
            try outcomes[mode]!.write(to: directory.appendingPathComponent("txm-" + mode + ".raw"))
        }
        let reread = try Data(contentsOf: raw)
        precondition(reread == source)
        let report: [String: Any] = [
            "upstream_revision": "1316940501398ea279f960ee7d838f93885730d4",
            "implementation": "working-tree production TXM", "legacy_output_sha256": baseline,
            "source_sha256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "both_equals_explicit_precheck": true, "explicit_precheck_equals_legacy_standard": true,
            "cases": results,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: directory.appendingPathComponent("txm-production-policies.json"))
        print("Eight production TXM policies passed; explicit precheck preserves legacy bytes")
    }
}
