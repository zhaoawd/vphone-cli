import CryptoKit
import Foundation
import VPhonePatchKit

// Compiled with unchanged TXM sources from the fixed upstream. Only memory is patched.
@main struct TXMUpstreamPolicyPreflight {
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
        let current = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("txm-current-records.json"))) as! [String: Any]
        var expected = source
        for record in current["standard"] as! [[String: Any]] {
            let hex = Array((record["after"] as! String).utf8)
            let bytes = stride(from: 0, to: hex.count, by: 2).map {
                UInt8(String(decoding: hex[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
            }
            let offset = record["offset"] as! Int
            expected.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        precondition(outcomes["prechecktrue"] == expected && outcomes["precheckfalse"] == expected,
                     "Upstream explicit precheck must preserve the measured baseline bytes")
        let reread = try Data(contentsOf: raw)
        precondition(reread == source)
        let report: [String: Any] = [
            "upstream_revision": "1316940501398ea279f960ee7d838f93885730d4",
            "source_sha256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "both_equals_explicit_precheck": true, "explicit_precheck_equals_current_standard": true,
            "cases": results,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: directory.appendingPathComponent("txm-upstream-policies.json"))
        print("Eight upstream TXM policy combinations passed; both selects precheck only; explicit precheck preserves current standard bytes")
    }
}
