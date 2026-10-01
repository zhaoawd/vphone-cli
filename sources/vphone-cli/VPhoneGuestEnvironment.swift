import CryptoKit
import Foundation
import VPhoneAPIKit
import VPhoneCore

// MARK: - Manifest

/// `scripts/guest_environment.json`, the library list shared with the T16
/// offline update and checked against the API daemon's list by tests.
struct VPhoneGuestEnvironmentManifest: Equatable {
    struct Library: Equatable {
        let name: String
        let stage: String
        let guest: String
        let loadedBy: String
    }

    let libraries: [Library]
    let loadAlias: String
    let loadAliasTarget: String

    var names: [String] { libraries.map(\.name) }

    static func load(_ url: URL) throws -> Self {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? Int == 1,
              let rows = object["libraries"] as? [[String: Any]], !rows.isEmpty,
              let alias = object["load_alias"] as? [String: Any],
              let aliasPath = alias["path"] as? String, let aliasTarget = alias["target"] as? String
        else { throw VPhoneGuestEnvironmentRefusal("manifest_invalid", "cannot read environment manifest \(url.path)") }
        let libraries = try rows.map { row -> Library in
            guard let name = row["name"] as? String, let stage = row["stage"] as? String,
                  let guest = row["guest"] as? String, let loadedBy = row["loaded_by"] as? String,
                  !name.contains("/"), !stage.hasPrefix("/"), !stage.contains("..")
            else { throw VPhoneGuestEnvironmentRefusal("manifest_invalid", "malformed library entry in \(url.path)") }
            return Library(name: name, stage: stage, guest: guest, loadedBy: loadedBy)
        }
        return Self(libraries: libraries, loadAlias: "/" + aliasPath, loadAliasTarget: aliasTarget)
    }
}

struct VPhoneGuestEnvironmentRefusal: Error {
    let code: String
    let message: String
    var fields: [String: Any] = [:]

    init(_ code: String, _ message: String, _ fields: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.fields = fields
    }
}

// MARK: - Candidates

/// Signed candidates from `make guest_components_build`. Each must be a
/// regular file whose SHA-256 equals the stage's manifest.json record and
/// that has LC_CODE_SIGNATURE, the same checks as `cfw_env_update.py`.
enum VPhoneGuestEnvironmentCandidates {
    struct Candidate: Equatable {
        let name: String
        let path: String
        let sha256: String
    }

    static func verify(stage: URL, manifest: VPhoneGuestEnvironmentManifest) throws -> [String: Candidate] {
        func refuse(_ message: String) -> VPhoneGuestEnvironmentRefusal {
            VPhoneGuestEnvironmentRefusal("candidate_invalid", message, ["components": stage.path])
        }
        let record = stage.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: record.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recorded = object["files_sha256"] as? [String: String]
        else { throw refuse("\(record.path) is missing or unreadable; run make guest_components_build or pass --components") }
        var result: [String: Candidate] = [:]
        for library in manifest.libraries {
            let file = stage.appendingPathComponent(library.stage)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let bytes = FileManager.default.contents(atPath: file.path)
            else { throw refuse("candidate \(file.path) is missing or not a regular file") }
            let digest = sha256(bytes)
            guard recorded[library.stage] == digest else {
                throw refuse("candidate \(file.path) differs from \(record.path) (\(recorded[library.stage] ?? "none") recorded, \(digest) found)")
            }
            guard hasCodeSignature(bytes) else { throw refuse("candidate \(file.path) is not a signed 64-bit Mach-O") }
            result[library.name] = Candidate(name: library.name, path: file.path, sha256: digest)
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when every 64-bit slice has LC_CODE_SIGNATURE.
    static func hasCodeSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        func u32(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return big ? value : value.byteSwapped
        }
        func signed(_ base: Int) -> Bool {
            guard u32(base) == 0xFEED_FACF, let count = u32(base + 16), let size = u32(base + 20) else { return false }
            var position = base + 32
            let end = position + Int(size)
            for _ in 0..<count {
                guard let command = u32(position), let length = u32(position + 4), length >= 8,
                      position + Int(length) <= end else { return false }
                if command == 0x1D { return true }
                position += Int(length)
            }
            return false
        }
        switch u32(0, big: true) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let wide = u32(0, big: true) == 0xCAFE_BABF
            guard let count = u32(4, big: true), count > 0, count < 64 else { return false }
            return (0..<Int(count)).allSatisfy { index in
                let entry = 8 + index * (wide ? 32 : 20)
                let offset: Int? = wide
                    ? u32(entry + 8, big: true).flatMap { high in u32(entry + 12, big: true).map { Int(high) << 32 | Int($0) } }
                    : u32(entry + 8, big: true).map(Int.init)
                return offset.map(signed) ?? false
            }
        default:
            return signed(0)
        }
    }
}

// MARK: - Updater

/// Host-control `environment_status`, `environment_update` and
/// `environment_rollback` (T17). Runs in the VM process against its API
/// session. File digests, mapped library copies and app behavior are
/// reported separately; no process is restarted unless the request names it
/// in `restart`, and SpringBoard, launchd and other processes outside
/// `restartable` are refused.
@MainActor
struct VPhoneGuestEnvironmentUpdater {
    static let commands = ["environment_status", "environment_update", "environment_rollback"]
    /// Restarted by SIGTERM; launchd starts it again for the next camera
    /// client (upstream 2.2.3 comment; not verified on a local guest).
    nonisolated static let restartable = ["cameracaptured"]
    static let staging = "/var/root/Library/Caches/vphone-environment"
    static let applicationNote = "not verified: this command checks files and mapped copies only; "
        + "camera and location behavior need their own acceptance"
    static let rebootNote = "reboot_required=false only means the daemon saw no reason to reboot; "
        + "it does not mean that running processes loaded the new files"

    let session: (any VPhoneHostAPISession)?
    let manifestURL: URL

    struct Outcome {
        var ok: Bool
        var error: String?
        var fields: [String: Any]
    }

    static func capabilities(_ session: (any VPhoneHostAPISession)?) -> [String: Bool] {
        let ready = session?.snapshot.state == .ready
        let caps = Set(session?.snapshot.health?.capabilities ?? [])
        return [
            "environment_status": ready && caps.contains("environment_update"),
            "environment_update": ready && caps.isSuperset(of: ["environment_update", "environment_transaction",
                                                                "files", "file_upload_identity"]),
            "environment_rollback": ready && caps.isSuperset(of: ["environment_update", "environment_transaction"]),
        ]
    }

    func execute(_ command: String, request: [String: Any]) async -> Outcome {
        do {
            switch command {
            case "environment_status": return try await status(request)
            case "environment_update": return try await update(request)
            default: return try await rollback(request)
            }
        } catch let refusal as VPhoneGuestEnvironmentRefusal {
            var fields = refusal.fields
            fields["code"] = refusal.code
            return Outcome(ok: false, error: refusal.message, fields: fields)
        } catch is CancellationError {
            return Outcome(ok: false, error: "command cancelled", fields: ["code": "command_cancelled", "operation_may_continue": true])
        } catch {
            return Outcome(ok: false, error: "environment command failed", fields: ["code": "api_transport", "operation_may_continue": true])
        }
    }

    // MARK: Requests

    private func components(_ request: [String: Any], required: Bool) throws -> URL? {
        guard let value = request["components"] else {
            if required { throw VPhoneGuestEnvironmentRefusal("invalid_argument", "components must name the candidate stage") }
            return nil
        }
        guard let path = value as? String, path.hasPrefix("/"), !path.contains("\0") else {
            throw VPhoneGuestEnvironmentRefusal("invalid_argument", "components must be an absolute path")
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func restartRequest(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let names = value as? [String], names.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            throw VPhoneGuestEnvironmentRefusal("invalid_argument", "restart must be an array of process names")
        }
        for name in names where !restartable.contains(name) {
            throw VPhoneGuestEnvironmentRefusal("restart_not_allowed",
                "\(name) is not restarted by the environment update; respring and reboot are never performed here",
                ["process": name, "allowed": restartable])
        }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private func ready(_ capabilities: [String]) throws -> (any VPhoneHostAPISession, UUID?) {
        guard let session, session.snapshot.state == .ready else {
            throw VPhoneGuestEnvironmentRefusal("api_not_ready", "the guest API session is not ready")
        }
        let declared = session.snapshot.health?.capabilities ?? []
        for capability in capabilities where !declared.contains(capability) {
            throw VPhoneGuestEnvironmentRefusal("capability_unavailable",
                "the guest API daemon does not declare \(capability)", ["capability": capability])
        }
        return (session, session.snapshot.generation)
    }

    private func manifest() throws -> VPhoneGuestEnvironmentManifest {
        try VPhoneGuestEnvironmentManifest.load(manifestURL)
    }

    // MARK: status

    private func status(_ request: [String: Any]) async throws -> Outcome {
        let stage = try components(request, required: false)
        let (session, generation) = try ready(["environment_update"])
        let manifest = try manifest()
        let candidates = try stage.map { try VPhoneGuestEnvironmentCandidates.verify(stage: $0, manifest: manifest) }
        let guest = try await GuestStatus.read(session, generation)
        var fields: [String: Any] = ["files": files(manifest, before: guest, candidates: candidates)]
        fields["assessment"] = assessment(manifest, guest: guest, candidates: candidates)
        let load = try await loadState(session, generation, manifest: manifest)
        fields["load"] = load.fields
        fields["activation"] = activation(replaced: [], load: load, manifest: manifest, reboot: nil, rootReadOnly: guest.rootReadOnly)
        fields["application"] = ["state": "not_verified", "note": Self.applicationNote]
        fields["transactions"] = guest.transactions
        fields["root_read_only"] = guest.rootReadOnly
        return Outcome(ok: true, fields: fields)
    }

    private func assessment(_ manifest: VPhoneGuestEnvironmentManifest, guest: GuestStatus,
                            candidates: [String: VPhoneGuestEnvironmentCandidates.Candidate]?) -> [String: Any] {
        if guest.names != manifest.names {
            return ["state": "environment_mismatch", "guest_libraries": guest.names, "host_libraries": manifest.names]
        }
        let reasons = migrationReasons(manifest, guest: guest)
        if !reasons.isEmpty { return ["state": "full_migration_required", "reasons": reasons] }
        guard let candidates else { return ["state": "no_candidates"] }
        let changed = manifest.names.filter { guest.sha256[$0] != candidates[$0]?.sha256 }
        return changed.isEmpty ? ["state": "already_current"] : ["state": "update_available", "replace": changed]
    }

    private func migrationReasons(_ manifest: VPhoneGuestEnvironmentManifest, guest: GuestStatus) -> [String] {
        var reasons = manifest.libraries.filter { guest.sha256[$0.name] == nil }.map {
            "\($0.guest.hasPrefix("/") ? $0.guest : "/" + $0.guest) is missing; the online update replaces existing libraries only"
        }
        if guest.aliasTarget != manifest.loadAliasTarget {
            reasons.append("\(manifest.loadAlias) points to \(guest.aliasTarget ?? "nothing"), not \(manifest.loadAliasTarget)")
        }
        return reasons
    }

    // MARK: update

    private func update(_ request: [String: Any]) async throws -> Outcome {
        guard let stage = try components(request, required: true) else {
            throw VPhoneGuestEnvironmentRefusal("invalid_argument", "components must name the candidate stage")
        }
        let restart = try Self.restartRequest(request["restart"])
        var required = ["environment_update", "environment_transaction", "files", "file_upload_identity"]
        if !restart.isEmpty { required.append("processes") }
        let (session, generation) = try ready(required)
        let manifest = try manifest()
        let candidates = try VPhoneGuestEnvironmentCandidates.verify(stage: stage, manifest: manifest)

        let before = try await GuestStatus.read(session, generation)
        guard before.names == manifest.names else {
            throw VPhoneGuestEnvironmentRefusal("environment_mismatch",
                "the guest daemon's environment library list differs from \(manifestURL.lastPathComponent)",
                ["guest_libraries": before.names, "host_libraries": manifest.names])
        }
        let reasons = migrationReasons(manifest, guest: before)
        guard reasons.isEmpty else {
            throw VPhoneGuestEnvironmentRefusal("full_migration_required",
                "the guest has no complete v2 environment; the online update does not install it",
                ["reasons": reasons, "files": files(manifest, before: before, candidates: candidates)])
        }
        let changed = manifest.names.filter { before.sha256[$0] != candidates[$0]?.sha256 }
        var results = Dictionary(uniqueKeysWithValues: manifest.names.map { ($0, changed.contains($0) ? "not_attempted" : "unchanged") })

        if changed.isEmpty {
            var fields: [String: Any] = ["outcome": "already_current",
                                         "files": files(manifest, before: before, after: before, candidates: candidates, results: results)]
            let load = try await loadState(session, generation, manifest: manifest)
            return try await finish(&fields, session, generation, manifest: manifest, load: load, replaced: [],
                                    reboot: nil, rootReadOnly: before.rootReadOnly, restart: restart)
        }

        // Upload, then confirm what the guest staged before anything is replaced.
        for name in changed {
            guard let candidate = candidates[name] else { continue }
            do {
                let upload = try await VPhoneAPIUpload.prepare(path: candidate.path)
                try check(session, generation)
                try await session.uploadFile(upload, path: Self.staging + "/" + name, permissions: "644")
            } catch let refusal as VPhoneGuestEnvironmentRefusal {
                throw refusal
            } catch {
                throw VPhoneGuestEnvironmentRefusal("upload_failed", "uploading \(name) failed; no library was replaced",
                    ["library": name, "api_code": apiCode(error),
                     "files": files(manifest, before: before, candidates: candidates, results: results)])
            }
        }
        let staged = try await GuestStatus.read(session, generation)
        for name in changed where staged.staged[name] != candidates[name]?.sha256 {
            throw VPhoneGuestEnvironmentRefusal("staged_digest_mismatch",
                "the staged copy of \(name) does not match the candidate; no library was replaced",
                ["library": name, "expected_sha256": candidates[name]?.sha256 ?? "",
                 "staged_sha256": staged.staged[name] ?? NSNull(),
                 "files": files(manifest, before: before, candidates: candidates, results: results)])
        }

        // Install. A failure inside the daemon is a result with its journal.
        let install: [String: Any]
        do {
            let value = try await session.call("environment.install", params: [
                "libraries": .array(changed.map { .object(["name": .string($0), "sha256": .string(candidates[$0]!.sha256)]) }),
            ], requiring: "environment_update")
            try check(session, generation, submitted: true)
            guard let object = environmentPlain(value) as? [String: Any] else { throw VPhoneGuestEnvironmentRefusal("api_protocol", "malformed install result") }
            install = object
        } catch let refusal as VPhoneGuestEnvironmentRefusal {
            throw refusal
        } catch {
            // The daemon may have replaced some files. Read back what it holds.
            let after = try? await GuestStatus.read(session, generation)
            var fields: [String: Any] = ["api_code": apiCode(error), "operation_may_continue": true,
                                         "files": files(manifest, before: before, after: after, candidates: candidates, results: results)]
            fields["recovery"] = [
                "transactions": after?.transactions ?? [],
                "steps": ["read `vphone-cli guest env status <vm>`: files whose guest digest equals the candidate were replaced",
                          "rerun `vphone-cli guest env update <vm>` to finish, or `vphone-cli guest env rollback <vm> <transaction>` "
                          + "with the newest transaction listed above"],
            ]
            throw VPhoneGuestEnvironmentRefusal("install_failed", "environment.install did not return a result", fields)
        }

        let journal = install["libraries"] as? [[String: Any]] ?? []
        for row in journal {
            if let name = row["name"] as? String, let state = row["state"] as? String { results[name] = state }
        }
        let complete = install["complete"] as? Bool ?? false
        let replaced = manifest.names.filter { results[$0] == "replaced" }
        let after = try await GuestStatus.read(session, generation)
        var fields: [String: Any] = ["outcome": complete ? "updated" : "partial_failure",
                                     "files": files(manifest, before: before, after: after, candidates: candidates, results: results),
                                     "transaction": install["id"] ?? NSNull()]
        let load = try await loadState(session, generation, manifest: manifest)
        let reboot = install["reboot_required"] as? Bool
        let rootReadOnly = install["root_read_only"] as? Bool
        guard complete else {
            let id = install["id"] as? String ?? "<transaction>"
            fields["recovery"] = [
                "transaction": install["id"] ?? NSNull(),
                "journal": install["journal"] ?? NSNull(),
                "replaced": journal.filter { $0["state"] as? String == "replaced" }.map {
                    ["name": $0["name"] ?? "", "previous_sha256": $0["previous_sha256"] ?? NSNull(),
                     "sha256": $0["sha256"] ?? NSNull(), "backup": $0["backup"] ?? NSNull()]
                },
                "failed": journal.first { $0["state"] as? String == "failed" }.map {
                    ["name": $0["name"] ?? "", "error": $0["error"] ?? NSNull()]
                } ?? NSNull(),
                "not_attempted": journal.filter { $0["state"] as? String == "not_attempted" }.compactMap { $0["name"] as? String },
                "steps": ["forward: rerun `vphone-cli guest env update <vm>`; it uploads and replaces only the libraries that still differ",
                          "backward: `vphone-cli guest env rollback <vm> \(id)` copies each backup listed in replaced back to /usr/lib"],
            ]
            fields["activation"] = activation(replaced: replaced, load: load, manifest: manifest, reboot: reboot, rootReadOnly: rootReadOnly)
            fields["load"] = load.fields
            fields["application"] = ["state": "not_verified", "note": Self.applicationNote]
            if !restart.isEmpty { fields["restart_skipped"] = "not run after a partial failure" }
            return Outcome(ok: false, error: "the environment update replaced only part of the requested libraries",
                           fields: fields.merging(["code": "partial_failure"]) { $1 })
        }
        return try await finish(&fields, session, generation, manifest: manifest, load: load, replaced: replaced,
                                reboot: reboot, rootReadOnly: rootReadOnly, restart: restart)
    }

    private func finish(_ fields: inout [String: Any], _ session: any VPhoneHostAPISession, _ generation: UUID?,
                        manifest: VPhoneGuestEnvironmentManifest, load: LoadState, replaced: [String],
                        reboot: Bool?, rootReadOnly: Bool?, restart: [String]) async throws -> Outcome {
        var activation = activation(replaced: replaced, load: load, manifest: manifest, reboot: reboot, rootReadOnly: rootReadOnly)
        fields["load"] = load.fields
        fields["application"] = ["state": "not_verified", "note": Self.applicationNote]
        var executed: [[String: Any]] = []
        var failure: String?
        for process in restart {
            do {
                let listed = try await session.call("processes.list", params: ["filter": .string(process)], requiring: "processes")
                try check(session, generation)
                let rows = (environmentPlain(listed) as? [String: Any])?["processes"] as? [[String: Any]] ?? []
                let pids = rows.filter { $0["name"] as? String == process }.compactMap { ($0["pid"] as? NSNumber)?.intValue }.filter { $0 > 1 }
                for pid in pids {
                    _ = try await session.call("processes.kill", params: ["pid": .number(Double(pid)), "signal": .string("TERM"),
                                                                          "force": .bool(true)], requiring: "processes")
                    try check(session, generation, submitted: true)
                }
                executed.append(["process": process, "pids": pids, "signal": "TERM",
                                 "note": pids.isEmpty ? "not running; it loads the installed file when it next starts"
                                     : "launchd starts it again for the next client (not verified locally)"])
            } catch {
                failure = process
                executed.append(["process": process, "error": apiCode(error)])
                break
            }
        }
        if var actions = activation["actions"] as? [[String: Any]] {
            for index in actions.indices where actions[index]["action"] as? String == "restart" {
                let process = actions[index]["process"] as? String ?? ""
                actions[index]["executed"] = executed.contains { $0["process"] as? String == process && $0["error"] == nil }
            }
            activation["actions"] = actions
        }
        activation["executed"] = executed
        fields["activation"] = activation
        if !executed.isEmpty, session.snapshot.health?.capabilities.contains("environment_activation") == true {
            fields["load_after_restart"] = try await loadState(session, generation, manifest: manifest).fields
        }
        if let failure {
            fields["code"] = "restart_failed"
            return Outcome(ok: false, error: "restarting \(failure) failed", fields: fields)
        }
        return Outcome(ok: true, fields: fields)
    }

    // MARK: rollback

    private func rollback(_ request: [String: Any]) async throws -> Outcome {
        guard let id = request["transaction"] as? String, !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { throw VPhoneGuestEnvironmentRefusal("invalid_argument", "transaction must be a transaction id from environment status") }
        let (session, generation) = try ready(["environment_update", "environment_transaction"])
        let manifest = try manifest()
        let value: VPhoneJSONValue
        do {
            value = try await session.call("environment.restore", params: ["transaction": .string(id)], requiring: "environment_transaction")
            try check(session, generation, submitted: true)
        } catch let refusal as VPhoneGuestEnvironmentRefusal {
            throw refusal
        } catch {
            throw VPhoneGuestEnvironmentRefusal("rollback_failed", "environment.restore did not complete",
                ["api_code": apiCode(error), "operation_may_continue": true])
        }
        let result = environmentPlain(value) as? [String: Any] ?? [:]
        let rows = result["libraries"] as? [[String: Any]] ?? []
        let restored = rows.filter { $0["state"] as? String == "restored" }.compactMap { $0["name"] as? String }
        let after = try? await GuestStatus.read(session, generation)
        let load = try await loadState(session, generation, manifest: manifest)
        var fields: [String: Any] = ["outcome": result["state"] ?? NSNull(), "transaction": id, "restored": restored,
                                     "journal": rows, "load": load.fields,
                                     "application": ["state": "not_verified", "note": Self.applicationNote],
                                     "activation": activation(replaced: restored, load: load, manifest: manifest,
                                                              reboot: result["reboot_required"] as? Bool,
                                                              rootReadOnly: result["root_read_only"] as? Bool)]
        if let after { fields["files"] = files(manifest, before: after, candidates: nil) }
        let complete = result["state"] as? String == "restored"
        if !complete { fields["code"] = "rollback_incomplete" }
        return Outcome(ok: complete, error: complete ? nil : "the rollback restored only part of the transaction", fields: fields)
    }

    // MARK: Guest state

    struct GuestStatus {
        var names: [String] = []
        var sha256: [String: String] = [:]
        var staged: [String: String] = [:]
        var aliasTarget: String?
        var rootReadOnly: Bool?
        var transactions: [Any] = []

        @MainActor
        static func read(_ session: any VPhoneHostAPISession, _ generation: UUID?) async throws -> GuestStatus {
            let value: VPhoneJSONValue
            do {
                value = try await session.call("environment.status", params: [:], requiring: "environment_update")
            } catch {
                throw VPhoneGuestEnvironmentRefusal(apiHostCode(error), "environment.status failed", ["api_code": apiCode(error)])
            }
            guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
                throw VPhoneGuestEnvironmentRefusal("api_stale_session", "the guest API session changed during the update",
                                                    ["operation_may_continue": true])
            }
            guard let object = environmentPlain(value) as? [String: Any], let rows = object["libraries"] as? [[String: Any]] else {
                throw VPhoneGuestEnvironmentRefusal("api_protocol", "malformed environment.status result")
            }
            var status = GuestStatus()
            for row in rows {
                guard let name = row["name"] as? String else { continue }
                status.names.append(name)
                if let sha = row["sha256"] as? String { status.sha256[name] = sha }
                if let sha = row["staged_sha256"] as? String { status.staged[name] = sha }
            }
            status.aliasTarget = (object["load_alias"] as? [String: Any])?["target"] as? String
            status.rootReadOnly = object["root_read_only"] as? Bool
            status.transactions = object["transactions"] as? [Any] ?? []
            return status
        }
    }

    private func check(_ session: any VPhoneHostAPISession, _ generation: UUID?, submitted: Bool = false) throws {
        try Task.checkCancellation()
        guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
            var fields: [String: Any] = [:]
            if submitted { fields["operation_may_continue"] = true }
            throw VPhoneGuestEnvironmentRefusal("api_stale_session", "the guest API session changed during the update", fields)
        }
    }

    // MARK: Files

    private func files(_ manifest: VPhoneGuestEnvironmentManifest, before: GuestStatus, after: GuestStatus? = nil,
                       candidates: [String: VPhoneGuestEnvironmentCandidates.Candidate]?,
                       results: [String: String]? = nil) -> [String: Any] {
        let rows = manifest.libraries.map { library -> [String: Any] in
            var row: [String: Any] = ["name": library.name, "guest": before.sha256[library.name] ?? NSNull()]
            if let candidate = candidates?[library.name] {
                row["candidate"] = candidate.sha256
                row["matches_candidate"] = before.sha256[library.name] == candidate.sha256
            }
            if let results {
                row["guest_before"] = before.sha256[library.name] ?? NSNull()
                row["result"] = results[library.name] ?? "unchanged"
                row.removeValue(forKey: "guest")
                row.removeValue(forKey: "matches_candidate")
            }
            if let after {
                row["guest_after"] = after.sha256[library.name] ?? NSNull()
                if let candidate = candidates?[library.name] {
                    row["verified"] = after.sha256[library.name] == candidate.sha256
                }
            }
            return row
        }
        var section: [String: Any] = ["libraries": rows]
        if let after, let candidates {
            section["all_current"] = manifest.names.allSatisfy { after.sha256[$0] == candidates[$0]?.sha256 }
        }
        return section
    }

    // MARK: Load state

    struct LoadState {
        var available: Bool
        var reason: String?
        var complete = false
        /// library -> (current pids, stale [(pid, name)])
        var libraries: [String: (current: [Int], stale: [(pid: Int, name: String)])] = [:]
        /// pid -> (name, libraries mapped as a replaced copy)
        var staleProcesses: [Int: (name: String, libraries: [String])] = [:]
        var uninspected: [Any] = []
        var scanned: Any = NSNull()
        var names: [String] = []

        var fields: [String: Any] {
            var fields: [String: Any] = ["source": available ? "environment.loaded" : "unavailable"]
            if let reason { fields["reason"] = reason }
            if available {
                fields["complete"] = complete
                fields["uninspected"] = uninspected
                fields["scanned"] = scanned
            }
            fields["libraries"] = names.map { name -> [String: Any] in
                guard available, let entry = libraries[name] else { return ["name": name, "state": "unknown"] }
                let state = !entry.stale.isEmpty ? "stale" : !entry.current.isEmpty ? "current" : "not_mapped"
                return ["name": name, "state": state, "current_pids": entry.current,
                        "stale": entry.stale.map { ["pid": $0.pid, "name": $0.name] }]
            }
            return fields
        }
    }

    private func loadState(_ session: any VPhoneHostAPISession, _ generation: UUID?,
                           manifest: VPhoneGuestEnvironmentManifest) async throws -> LoadState {
        guard session.snapshot.health?.capabilities.contains("environment_activation") == true else {
            return LoadState(available: false, reason: "the guest API daemon does not declare environment_activation",
                             names: manifest.names)
        }
        let value: VPhoneJSONValue
        do {
            value = try await session.call("environment.loaded", params: [:], requiring: "environment_activation")
            try check(session, generation)
        } catch let refusal as VPhoneGuestEnvironmentRefusal {
            throw refusal
        } catch {
            return LoadState(available: false, reason: "environment.loaded failed (\(apiCode(error)))", names: manifest.names)
        }
        guard let object = environmentPlain(value) as? [String: Any], let processes = object["processes"] as? [[String: Any]] else {
            return LoadState(available: false, reason: "malformed environment.loaded result", names: manifest.names)
        }
        var state = LoadState(available: true, names: manifest.names)
        for name in manifest.names { state.libraries[name] = ([], []) }
        for process in processes {
            guard let pid = (process["pid"] as? NSNumber)?.intValue else { continue }
            let name = process["name"] as? String ?? ""
            for mapping in process["mappings"] as? [[String: Any]] ?? [] {
                guard let library = mapping["library"] as? String, state.libraries[library] != nil else { continue }
                if mapping["state"] as? String == "current" {
                    state.libraries[library]!.current.append(pid)
                } else {
                    state.libraries[library]!.stale.append((pid, name))
                    state.staleProcesses[pid, default: (name, [])].libraries.append(library)
                }
            }
        }
        state.uninspected = object["uninspected"] as? [Any] ?? []
        state.complete = state.uninspected.isEmpty
        state.scanned = object["scanned"] ?? NSNull()
        return state
    }

    // MARK: Activation

    /// What it takes for running processes to use the installed files.
    /// From mappings when the daemon reports them, otherwise from the
    /// manifest's loaders. Only `restart` actions can be run by this command.
    private func activation(replaced: [String], load: LoadState, manifest: VPhoneGuestEnvironmentManifest,
                            reboot: Bool?, rootReadOnly: Bool?) -> [String: Any] {
        var actions: [[String: Any]] = []
        func add(_ kind: String, _ process: String, pid: Int? = nil, libraries: [String], reason: String) {
            if let index = actions.firstIndex(where: { $0["action"] as? String == kind && $0["process"] as? String == process
                && $0["pid"] as? Int == pid }) {
                let merged = Set(actions[index]["libraries"] as? [String] ?? []).union(libraries)
                actions[index]["libraries"] = manifest.names.filter(merged.contains)
                return
            }
            var action: [String: Any] = ["action": kind, "process": process, "libraries": libraries, "reason": reason,
                                         "executed": false]
            if let pid { action["pid"] = pid }
            switch kind {
            case "reboot": action["how"] = "not performed; reboot the guest explicitly"
            case "respring": action["how"] = "not performed; respring explicitly when the screen state allows (rpc system.respring)"
            case "restart": action["how"] = "pass --restart \(process) to run it"
            default: action["how"] = "not performed; terminate and start this process or app explicitly"
            }
            actions.append(action)
        }
        if load.available {
            for pid in load.staleProcesses.keys.sorted() {
                guard let entry = load.staleProcesses[pid] else { continue }
                let list = entry.libraries.joined(separator: ", ")
                if pid == 1 {
                    add("reboot", entry.name, pid: pid, libraries: entry.libraries,
                        reason: "launchd (pid 1) maps a replaced copy of \(list); launchd is not restarted without a guest reboot")
                } else if entry.name == "SpringBoard" {
                    add("respring", entry.name, pid: pid, libraries: entry.libraries,
                        reason: "SpringBoard maps a replaced copy of \(list)")
                } else if Self.restartable.contains(entry.name) {
                    add("restart", entry.name, pid: pid, libraries: entry.libraries,
                        reason: "\(entry.name) maps a replaced copy of \(list)")
                } else {
                    add("relaunch", entry.name, pid: pid, libraries: entry.libraries,
                        reason: "\(entry.name) maps a replaced copy of \(list)")
                }
            }
        } else {
            for name in replaced {
                switch name {
                case "launchdhook-vphone.dylib":
                    add("reboot", "launchd", libraries: [name], reason: "launchd loaded \(name) at boot through /vh")
                case "SystemHook-vphone.dylib":
                    add("respring", "SpringBoard", libraries: [name], reason: "SpringBoard is an injection target and keeps the copy it mapped")
                    add("restart", "cameracaptured", libraries: [name], reason: "cameracaptured is an injection target")
                    add("relaunch", "running apps and bootstrap processes", libraries: [name],
                        reason: "processes started before the update keep the copy they mapped")
                case "libvcamcaptured.dylib":
                    add("restart", "cameracaptured", libraries: [name], reason: "SystemHook loads \(name) when cameracaptured starts")
                case "libvlocation.dylib":
                    add("respring", "SpringBoard", libraries: [name], reason: "SystemHook loads \(name) into app paths, SpringBoard included")
                    add("relaunch", "running apps", libraries: [name], reason: "apps load \(name) when they start")
                default:
                    add("relaunch", "running camera client apps", libraries: [name],
                        reason: "SystemHook loads \(name) into apps that use AVFoundation when they start")
                }
            }
        }
        if reboot == true, !actions.contains(where: { $0["action"] as? String == "reboot" }) {
            add("reboot", "guest", libraries: replaced.filter { $0 == "launchdhook-vphone.dylib" },
                reason: rootReadOnly == false ? "the root filesystem stayed writable after the replacement"
                    : "the daemon reported reboot_required")
        }
        var fields: [String: Any] = ["automatic_restart": false, "basis": load.available ? "mappings" : "manifest",
                                     "actions": actions, "executed": [Any](), "note": Self.rebootNote]
        fields["daemon_reboot_required"] = reboot ?? NSNull()
        fields["root_read_only"] = rootReadOnly ?? NSNull()
        return fields
    }
}

// MARK: - JSON helpers

func environmentPlain(_ value: VPhoneJSONValue) -> Any {
    switch value {
    case let .object(fields): fields.mapValues(environmentPlain)
    case let .array(items): items.map(environmentPlain)
    case let .string(text): text
    case let .number(number):
        number.rounded() == number && abs(number) < 1e15 ? NSNumber(value: Int(number)) : NSNumber(value: number)
    case let .bool(flag): flag
    case .null: NSNull()
    }
}

private func apiCode(_ error: any Error) -> String {
    (error as? VPhoneAPIError)?.code ?? (error is CancellationError ? "cancelled" : "transport")
}

@MainActor private func apiHostCode(_ error: any Error) -> String {
    guard let error = error as? VPhoneAPIError else { return "api_transport" }
    return VPhoneHostAPICommands.hostCode(forAPIError: error.code) ?? "api_guest_error"
}
