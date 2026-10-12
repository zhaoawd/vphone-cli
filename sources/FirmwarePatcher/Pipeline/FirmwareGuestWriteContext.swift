import CryptoKit
import Foundation

/// Narrow wire context for the less filesystem's existing Python suboperations.
/// The parent transaction retains its own output validation and PatchRecord rules.
enum FirmwareGuestWriteContext {
    static func environment(record: FirmwareDesiredPlanStore.Record, directory: URL, transaction: URL) throws -> [String: String] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let encoded = try JSONEncoder().encode(record)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any], let identity = object["identity"] else {
            throw FirmwareDesiredPlanStore.Failure.corrupt
        }
        let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        let context: [String: Any] = ["schemaVersion": 1, "vmDirectory": directory.path, "identity": identity,
            "generationID": record.generationID, "catalogSHA256": record.catalogSHA256, "planSHA256": record.planSHA256,
            "upstreamTarget": record.upstreamTarget, "variant": "less", "verifierPath": executable.path,
            "verifierSHA256": digest, "guestEnvironment": "classic", "spoofBuild": "", "disableLaunchdHook": "0",
            "filesystemTransaction": transaction.path]
        let json = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["VPHONE_FROZEN_PLAN": directory.appendingPathComponent(FirmwareDesiredPlanStore.filename).path,
                "VPHONE_FROZEN_PLAN_SHA256": try record.sha256, "VPHONE_FROZEN_CONTEXT": String(decoding: json, as: UTF8.self),
                "VPHONE_GUEST_EVIDENCE": transaction.appendingPathComponent("guest-changes.jsonl").path]
    }
}
