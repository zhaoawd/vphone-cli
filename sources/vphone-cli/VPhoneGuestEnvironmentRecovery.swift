import Foundation
import VPhoneAPIKit

/// Historical request data used only to prove termination and release Stop's
/// exclusion lease. It cannot authorize upload, restore, or origin publication.
struct VPhoneGuestEnvironmentRecovery {
    let context: [String: String]
    let transaction: String
    let before: [String: String]
    let requested: [String: String]
    let restoring: Bool
    var originalRows: [[String: String]] = []
    var originalContext: [String: String]? = nil
    var originalBefore: [String: String]? = nil

    @MainActor
    func hasTerminated(_ session: any VPhoneHostAPISession) async -> Bool {
        let initial = session.snapshot
        guard initial.state == .ready, initial.vmInstanceID == context["vm_instance"],
              initial.health?.instanceID == context["daemon_instance"],
              initial.health?.binaryHash == context["daemon_sha256"],
              let status = try? await VPhoneGuestEnvironmentUpdater.GuestStatus.read(session, initial.generation),
              session.snapshot.health?.instanceID == initial.health?.instanceID,
              session.snapshot.health?.binaryHash == initial.health?.binaryHash,
              status.workerIdle, status.rootReadOnly == true,
              status.daemonInstance == context["daemon_instance"],
              status.eligibility["eligible"] as? Bool == true,
              status.eligibility["mode"] as? String == context["mode"],
              status.eligibility["daemon_sha256"] as? String == context["daemon_sha256"],
              Set(status.names) == Set(before.keys), status.names.count == before.count else { return false }
        let matches = status.transactions.compactMap { $0 as? [String: Any] }.filter { $0["id"] as? String == transaction }
        guard matches.count == 1 else { return false }
        let journal = matches[0]
        guard journal[restoring ? "restore_context" : "context"] as? [String: String] == context,
              journal["root_read_only"] as? Bool == true,
              let state = journal["state"] as? String,
              (restoring ? ["restored", "restore_incomplete"] : ["complete", "incomplete"]).contains(state),
              journal["after_files"] as? [String: String] == status.sha256,
              let rows = journal["libraries"] as? [[String: Any]] else { return false }
        if !restoring, journal["before_files"] as? [String: String] != before { return false }
        var expected = before, seen = Set<String>()
        if restoring {
            guard let originalContext, let originalBefore,
                  journal["context"] as? [String: String] == originalContext,
                  journal["before_files"] as? [String: String] == originalBefore,
                  rows.count == originalRows.count else { return false }
            var failed = false
            for (row, original) in zip(rows, originalRows) {
                guard let name = original["name"], seen.insert(name).inserted,
                      ["name", "sha256", "previous_sha256", "backup"].allSatisfy({ row[$0] as? String == original[$0] }),
                      let result = row["state"] as? String else { return false }
                if let wanted = requested[name] {
                    guard original["state"] == "replaced", original["previous_sha256"] == wanted else { return false }
                    if failed { guard result == "replaced" else { return false } }
                    else if result == "restore_failed" { failed = true }
                    else { guard result == "restored" else { return false }; expected[name] = wanted }
                } else { guard result == original["state"] else { return false } }
            }
            return (state == "restored") == !failed && status.sha256 == expected
        }
        for row in rows {
            guard let name = row["name"] as? String, seen.insert(name).inserted,
                  let wanted = requested[name], row["sha256"] as? String == wanted,
                  let result = row["state"] as? String else { return false }
            if result == "replaced" { expected[name] = wanted }
            else if !["failed", "not_attempted"].contains(result) { return false }
        }
        return seen == Set(requested.keys) && status.sha256 == expected
    }
}
