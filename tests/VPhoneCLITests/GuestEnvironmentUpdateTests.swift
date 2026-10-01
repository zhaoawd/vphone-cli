import ArgumentParser
import CryptoKit
import Foundation
@testable import VPhoneAPIKit
import XCTest
@testable import vphone_cli

// MARK: - API daemon stand-in

/// Keeps the guest side of environment.status / install / loaded / restore
/// and processes.list / kill in memory, like the local API daemon.
@MainActor
final class EnvironmentDaemonFake: VPhoneHostAPISession {
    var caps = ["session_identity", "files", "file_upload_identity", "processes",
                "environment_update", "environment_transaction", "environment_activation"]
    var generation = UUID()
    var installed: [String: String?] = [:]
    var staged: [String: String] = [:]
    var aliasTarget: String? = "/usr/lib/launchdhook-vphone.dylib"
    var daemonLibraries = VPhoneGuestEnvironmentTestSupport.names
    /// Changes what the guest records for an upload (a corrupted transfer).
    var corruptUploads: Set<String> = []
    /// Index of the replacement that fails inside environment.install.
    var failReplacementAt: Int?
    var rootStaysWritable = false
    /// pid -> (name, [library: stale?]); nil stale means current.
    var processes: [Int: (name: String, maps: [String: Bool])] = [:]
    var uninspected: [[String: VPhoneJSONValue]] = []
    var calls: [(method: String, params: [String: VPhoneJSONValue])] = []
    var uploads: [String] = []
    var killed: [Int] = []

    init() {
        for name in VPhoneGuestEnvironmentTestSupport.names { installed[name] = "old-" + name }
    }

    var snapshot: VPhoneAPISession.Snapshot {
        let health: [String: Any] = ["apiVersion": 1, "binaryHash": String(repeating: "b", count: 64),
                                     "capabilities": caps, "instanceID": "6A5A4D0B-6D53-4A4B-8F2B-0B8E7E3F7A11"]
        let value: [String: Any] = ["vmInstanceID": "fixture", "state": "ready",
                                    "generation": generation.uuidString, "health": health]
        return try! JSONDecoder().decode(VPhoneAPISession.Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func uploadFile(_ source: VPhoneAPIUpload, path: String, permissions: String) async throws {
        uploads.append(path)
        let name = (path as NSString).lastPathComponent
        XCTAssertEqual((path as NSString).deletingLastPathComponent, "/var/root/Library/Caches/vphone-environment")
        let data = try Data(contentsOf: try source.file)
        staged[name] = corruptUploads.contains(name) ? "0" + String(Self.digest(data).dropFirst()) : Self.digest(data)
    }

    func downloadFile(path: String, maximumBytes: Int, stagingDirectory: URL) async throws -> VPhoneAPIDownload {
        throw URLError(.unsupportedURL)
    }

    func call(_ method: String, params: [String: VPhoneJSONValue], requiring capability: String?) async throws -> VPhoneJSONValue {
        calls.append((method, params))
        switch method {
        case "environment.status":
            return .object([
                "libraries": .array(daemonLibraries.map { name in
                    .object(["name": .string(name), "sha256": (installed[name] ?? nil).map { .string($0) } ?? .null,
                             "staged_sha256": staged[name].map { .string($0) } ?? .null])
                }),
                "staging": .string("/var/root/Library/Caches/vphone-environment"),
                "root_read_only": .bool(true),
                "load_alias": .object(["path": .string("/vh"), "target": aliasTarget.map { .string($0) } ?? .null]),
                "transactions": .array([]),
            ])
        case "environment.install":
            guard case let .array(entries)? = params["libraries"] else { throw apiError("invalid_operation", "libraries") }
            var rows: [VPhoneJSONValue] = []
            var failed = false
            for (index, entry) in entries.enumerated() {
                guard case let .object(fields) = entry, case let .string(name)? = fields["name"],
                      case let .string(sha)? = fields["sha256"] else { throw apiError("invalid_operation", "entry") }
                guard staged[name] == sha else { throw apiError("invalid_operation", "\(name) does not match its SHA-256") }
                var row: [String: VPhoneJSONValue] = ["name": .string(name), "sha256": .string(sha),
                    "previous_sha256": .string((installed[name] ?? nil) ?? ""),
                    "backup": .string("/var/root/Library/Caches/vphone-environment/transactions/T1/backup/\(name)")]
                if failed {
                    row["state"] = .string("not_attempted")
                } else if index == failReplacementAt {
                    row["state"] = .string("failed")
                    row["error"] = .string("Could not install /usr/lib/\(name): Input/output error")
                    failed = true
                } else {
                    row["state"] = .string("replaced")
                    installed[name] = sha
                    staged[name] = nil
                }
                rows.append(.object(row))
            }
            let replaced = rows.compactMap { row -> String? in
                guard case let .object(fields) = row, fields["state"] == .string("replaced"),
                      case let .string(name)? = fields["name"] else { return nil }
                return name
            }
            return .object([
                "id": .string("T1"), "state": .string(failed ? "incomplete" : "complete"), "complete": .bool(!failed),
                "libraries": .array(rows), "installed": .array(replaced.map { .string($0) }),
                "journal": .string("/var/root/Library/Caches/vphone-environment/transactions/T1/journal.json"),
                "reboot_required": .bool(rootStaysWritable || replaced.contains("launchdhook-vphone.dylib")),
                "root_read_only": .bool(!rootStaysWritable), "restarted_pids": .array([]),
            ])
        case "environment.restore":
            return .object(["id": params["transaction"] ?? .null, "state": .string("restored"),
                            "libraries": .array([.object(["name": .string("libcamfix.dylib"), "state": .string("restored")])])])
        case "environment.loaded":
            return .object([
                "processes": .array(processes.keys.sorted().map { pid in
                    let process = processes[pid]!
                    return .object(["pid": .number(Double(pid)), "name": .string(process.name),
                                    "mappings": .array(process.maps.keys.sorted().map { library in
                                        .object(["library": .string(library),
                                                 "state": .string(process.maps[library]! ? "stale" : "current")])
                                    })])
                }),
                "uninspected": .array(uninspected.map { .object($0) }), "scanned": .number(Double(processes.count)),
            ])
        case "processes.list":
            guard case let .string(filter)? = params["filter"] else { throw apiError("invalid_operation", "filter") }
            return .object(["processes": .array(processes.keys.sorted().filter { processes[$0]!.name.contains(filter) }.map {
                .object(["pid": .number(Double($0)), "name": .string(processes[$0]!.name)])
            })])
        case "processes.kill":
            guard case let .number(pid)? = params["pid"] else { throw apiError("invalid_operation", "pid") }
            killed.append(Int(pid))
            processes[Int(pid)] = nil
            return .object(["pid": .number(pid), "signal": params["signal"] ?? .null])
        default:
            throw apiError("invalid_operation", "unexpected \(method)")
        }
    }

    var methods: [String] { calls.map(\.method) }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum VPhoneGuestEnvironmentTestSupport {
    static let names = ["launchdhook-vphone.dylib", "SystemHook-vphone.dylib", "libvcamcaptured.dylib",
                        "libcamfix.dylib", "libvlocation.dylib"]
    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var manifestURL: URL { repository.appendingPathComponent("scripts/guest_environment.json") }

    /// A minimal 64-bit Mach-O with LC_CODE_SIGNATURE and a distinct payload.
    static func signedMachO(_ marker: String, signature: Bool = true) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value: UInt32 in [0xFEED_FACF, 0x0100_000C, 2, 6, 1, 16, 0, 0] { put(value) }
        put(signature ? 0x1D : 0x26); put(16); put(0); put(0)
        data.append(Data(marker.utf8))
        return data
    }

    /// Writes a candidate stage with manifest.json; returns name -> sha256.
    static func stage(at root: URL, marker: String = "new", signature: Bool = true) throws -> [String: String] {
        let manifest = try VPhoneGuestEnvironmentManifest.load(manifestURL)
        var recorded: [String: String] = [:]
        var digests: [String: String] = [:]
        for library in manifest.libraries {
            let file = root.appendingPathComponent(library.stage)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = signedMachO(marker + library.name, signature: signature)
            try data.write(to: file)
            recorded[library.stage] = EnvironmentDaemonFake.digest(data)
            digests[library.name] = EnvironmentDaemonFake.digest(data)
        }
        try JSONSerialization.data(withJSONObject: ["files_sha256": recorded]).write(to: root.appendingPathComponent("manifest.json"))
        return digests
    }
}

// MARK: - Tests

@MainActor
final class GuestEnvironmentUpdateTests: XCTestCase {
    private var stage: URL!
    private var candidates: [String: String] = [:]

    override func setUp() async throws {
        stage = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-env-stage-\(UUID())")
        candidates = try VPhoneGuestEnvironmentTestSupport.stage(at: stage)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stage)
    }

    private func run(_ api: EnvironmentDaemonFake, _ fields: [String: Any]) async throws -> [String: Any] {
        let executor = VPhoneHostCommandExecutor(apiSession: api,
                                                 environmentManifest: VPhoneGuestEnvironmentTestSupport.manifestURL)
        let data = await executor.execute(try JSONSerialization.data(withJSONObject: fields))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func update(_ api: EnvironmentDaemonFake, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        try await run(api, ["t": "environment_update", "components": stage.path].merging(extra) { $1 })
    }

    private func current(_ api: EnvironmentDaemonFake, except names: [String] = []) {
        for (name, sha) in candidates where !names.contains(name) { api.installed[name] = sha }
    }

    private func library(_ section: Any?, _ name: String) throws -> [String: Any] {
        let rows = try XCTUnwrap((section as? [String: Any])?["libraries"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["name"] as? String == name })
    }

    private func actions(_ result: [String: Any]) -> [[String: Any]] {
        (result["activation"] as? [String: Any])?["actions"] as? [[String: Any]] ?? []
    }

    // MARK: Files

    func testAllCurrentUploadsAndInstallsNothing() async throws {
        let api = EnvironmentDaemonFake()
        current(api)
        api.processes = [1: ("launchd", ["launchdhook-vphone.dylib": false])]
        let result = try await update(api)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "already_current")
        XCTAssertEqual(api.methods, ["environment.status", "environment.loaded"])
        XCTAssertTrue(api.uploads.isEmpty)
        let files = try XCTUnwrap(result["files"] as? [String: Any])
        XCTAssertEqual(files["all_current"] as? Bool, true)
        XCTAssertEqual(try library(files, "libcamfix.dylib")["result"] as? String, "unchanged")
        XCTAssertEqual(try library(result["load"], "launchdhook-vphone.dylib")["state"] as? String, "current")
        XCTAssertEqual((result["application"] as? [String: Any])?["state"] as? String, "not_verified")
        XCTAssertTrue(actions(result).isEmpty)
    }

    func testOnlyDifferingLibrariesAreUploadedVerifiedAndReplaced() async throws {
        let api = EnvironmentDaemonFake()
        current(api, except: ["libcamfix.dylib", "libvcamcaptured.dylib"])
        api.processes = [1: ("launchd", ["launchdhook-vphone.dylib": false]),
                         310: ("cameracaptured", ["libvcamcaptured.dylib": true, "SystemHook-vphone.dylib": false])]
        let result = try await update(api)
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["outcome"] as? String, "updated")
        XCTAssertEqual(api.uploads.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["libcamfix.dylib", "libvcamcaptured.dylib"])
        XCTAssertEqual(api.methods, ["environment.status", "environment.status", "environment.install",
                                     "environment.status", "environment.loaded"])
        guard case let .array(entries)? = api.calls[2].params["libraries"] else { return XCTFail("install params") }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(api.installed["libcamfix.dylib"], candidates["libcamfix.dylib"])
        let camfix = try library(result["files"], "libcamfix.dylib")
        XCTAssertEqual(camfix["result"] as? String, "replaced")
        XCTAssertEqual(camfix["verified"] as? Bool, true)
        XCTAssertEqual(camfix["guest_after"] as? String, candidates["libcamfix.dylib"])
        XCTAssertEqual(try library(result["files"], "libvlocation.dylib")["result"] as? String, "unchanged")
        // Files verified; the camera daemon still maps the replaced copy.
        let vcam = try library(result["load"], "libvcamcaptured.dylib")
        XCTAssertEqual(vcam["state"] as? String, "stale")
        let restart = try XCTUnwrap(actions(result).first { $0["action"] as? String == "restart" })
        XCTAssertEqual(restart["process"] as? String, "cameracaptured")
        XCTAssertEqual(restart["executed"] as? Bool, false)
        XCTAssertTrue(api.killed.isEmpty)
        XCTAssertEqual((result["activation"] as? [String: Any])?["automatic_restart"] as? Bool, false)
    }

    func testStagedDigestMismatchIsRefusedBeforeInstall() async throws {
        let api = EnvironmentDaemonFake()
        current(api, except: ["libcamfix.dylib", "libvlocation.dylib"])
        api.corruptUploads = ["libvlocation.dylib"]
        let result = try await update(api)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["code"] as? String, "staged_digest_mismatch")
        XCTAssertEqual(result["library"] as? String, "libvlocation.dylib")
        XCTAssertFalse(api.methods.contains("environment.install"))
        XCTAssertEqual(api.installed["libcamfix.dylib"], "old-libcamfix.dylib")
        XCTAssertEqual(try library(result["files"], "libcamfix.dylib")["result"] as? String, "not_attempted")
    }

    func testFailedReplacementReturnsRecoveryRecordAndNoOverallSuccess() async throws {
        let api = EnvironmentDaemonFake()
        current(api, except: ["SystemHook-vphone.dylib", "libcamfix.dylib", "libvlocation.dylib"])
        api.failReplacementAt = 1
        let result = try await update(api)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["code"] as? String, "partial_failure")
        XCTAssertEqual(result["outcome"] as? String, "partial_failure")
        let recovery = try XCTUnwrap(result["recovery"] as? [String: Any])
        XCTAssertEqual(recovery["transaction"] as? String, "T1")
        XCTAssertEqual(recovery["journal"] as? String,
                       "/var/root/Library/Caches/vphone-environment/transactions/T1/journal.json")
        let replaced = try XCTUnwrap(recovery["replaced"] as? [[String: Any]])
        XCTAssertEqual(replaced.map { $0["name"] as? String }, ["SystemHook-vphone.dylib"])
        XCTAssertEqual(replaced.first?["backup"] as? String,
                       "/var/root/Library/Caches/vphone-environment/transactions/T1/backup/SystemHook-vphone.dylib")
        XCTAssertEqual(replaced.first?["previous_sha256"] as? String, "old-SystemHook-vphone.dylib")
        XCTAssertEqual((recovery["failed"] as? [String: Any])?["name"] as? String, "libcamfix.dylib")
        XCTAssertEqual(recovery["not_attempted"] as? [String], ["libvlocation.dylib"])
        let steps = try XCTUnwrap(recovery["steps"] as? [String])
        XCTAssertTrue(steps.contains { $0.contains("guest env rollback") && $0.contains("T1") })
        XCTAssertTrue(steps.contains { $0.contains("guest env update") })
        XCTAssertEqual(try library(result["files"], "SystemHook-vphone.dylib")["result"] as? String, "replaced")
        XCTAssertEqual(try library(result["files"], "libcamfix.dylib")["result"] as? String, "failed")
        XCTAssertEqual(try library(result["files"], "libvlocation.dylib")["result"] as? String, "not_attempted")
    }

    func testMissingGuestLibraryOrAliasNeedsFullMigration() async throws {
        let api = EnvironmentDaemonFake()
        api.installed["libvlocation.dylib"] = .some(nil)
        var result = try await update(api)
        XCTAssertEqual(result["code"] as? String, "full_migration_required")
        XCTAssertTrue(api.uploads.isEmpty)
        let fresh = EnvironmentDaemonFake()
        fresh.aliasTarget = nil
        result = try await update(fresh)
        XCTAssertEqual(result["code"] as? String, "full_migration_required")
        XCTAssertEqual(fresh.methods, ["environment.status"])
        let mismatch = EnvironmentDaemonFake()
        mismatch.daemonLibraries = Array(VPhoneGuestEnvironmentTestSupport.names.dropLast()) + ["libmisfix.dylib"]
        result = try await update(mismatch)
        XCTAssertEqual(result["code"] as? String, "environment_mismatch")
        XCTAssertTrue(mismatch.uploads.isEmpty)
    }

    func testCandidateStageIsVerifiedBeforeGuestContact() async throws {
        let api = EnvironmentDaemonFake()
        let unsigned = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-env-unsigned-\(UUID())")
        defer { try? FileManager.default.removeItem(at: unsigned) }
        _ = try VPhoneGuestEnvironmentTestSupport.stage(at: unsigned, signature: false)
        var result = try await run(api, ["t": "environment_update", "components": unsigned.path])
        XCTAssertEqual(result["code"] as? String, "candidate_invalid")
        try Data("tampered".utf8).write(to: stage.appendingPathComponent("camfix/libcamfix.dylib"))
        result = try await update(api)
        XCTAssertEqual(result["code"] as? String, "candidate_invalid")
        XCTAssertTrue(api.calls.isEmpty)
    }

    // MARK: Load state and activation

    func testUnknownLoadStateFallsBackToManifestActions() async throws {
        let api = EnvironmentDaemonFake()
        api.caps.removeAll { $0 == "environment_activation" }
        current(api, except: ["launchdhook-vphone.dylib", "libvlocation.dylib"])
        let result = try await update(api)
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertFalse(api.methods.contains("environment.loaded"))
        let load = try XCTUnwrap(result["load"] as? [String: Any])
        XCTAssertEqual(load["source"] as? String, "unavailable")
        XCTAssertEqual(try library(load, "libvlocation.dylib")["state"] as? String, "unknown")
        let activation = try XCTUnwrap(result["activation"] as? [String: Any])
        XCTAssertEqual(activation["basis"] as? String, "manifest")
        XCTAssertEqual(activation["daemon_reboot_required"] as? Bool, true)
        let kinds = Set(actions(result).compactMap { $0["action"] as? String })
        XCTAssertTrue(kinds.contains("reboot"))
        XCTAssertTrue(kinds.contains("respring"))
        XCTAssertTrue(actions(result).allSatisfy { $0["executed"] as? Bool == false })
    }

    func testRebootRequiredFalseIsNotReportedAsLoaded() async throws {
        let api = EnvironmentDaemonFake()
        api.caps.removeAll { $0 == "environment_activation" }
        current(api, except: ["libcamfix.dylib"])
        let result = try await update(api)
        let activation = try XCTUnwrap(result["activation"] as? [String: Any])
        XCTAssertEqual(activation["daemon_reboot_required"] as? Bool, false)
        XCTAssertEqual(try library(result["load"], "libcamfix.dylib")["state"] as? String, "unknown")
        XCTAssertTrue((activation["note"] as? String)?.contains("reboot_required=false") == true)
    }

    func testRespringIsReportedButNeverPerformed() async throws {
        let api = EnvironmentDaemonFake()
        current(api, except: ["libvlocation.dylib"])
        api.processes = [55: ("SpringBoard", ["libvlocation.dylib": true, "SystemHook-vphone.dylib": false]),
                         310: ("cameracaptured", ["libvcamcaptured.dylib": false])]
        let result = try await update(api, ["restart": ["cameracaptured"]])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        let respring = try XCTUnwrap(actions(result).first { $0["action"] as? String == "respring" })
        XCTAssertEqual(respring["executed"] as? Bool, false)
        XCTAssertEqual(respring["pid"] as? Int, 55)
        XCTAssertTrue((respring["reason"] as? String)?.contains("libvlocation.dylib") == true)
        XCTAssertFalse(api.killed.contains(55))
        XCTAssertFalse(api.methods.contains("system.respring"))
        // The explicitly requested whitelist restart ran.
        XCTAssertEqual(api.killed, [310])
        let executed = try XCTUnwrap((result["activation"] as? [String: Any])?["executed"] as? [[String: Any]])
        XCTAssertEqual(executed.first?["process"] as? String, "cameracaptured")
        XCTAssertEqual(executed.first?["pids"] as? [Int], [310])
        guard let kill = api.calls.first(where: { $0.method == "processes.kill" }) else { return XCTFail("no kill") }
        XCTAssertEqual(kill.params["signal"], .string("TERM"))
        XCTAssertEqual(kill.params["force"], .bool(true))
    }

    func testRestartOutsideTheWhitelistIsRefusedBeforeGuestContact() async throws {
        for process in ["SpringBoard", "launchd", "installd", "misagent", "Camera", ""] {
            let api = EnvironmentDaemonFake()
            let result = try await update(api, ["restart": [process]])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["code"] as? String, process.isEmpty ? "invalid_argument" : "restart_not_allowed", process)
            XCTAssertTrue(api.calls.isEmpty, process)
        }
        let api = EnvironmentDaemonFake()
        let result = try await update(api, ["restart": "cameracaptured"])
        XCTAssertEqual(result["code"] as? String, "invalid_argument")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testUninspectedProcessesMakeLoadStatePartial() async throws {
        let api = EnvironmentDaemonFake()
        current(api)
        api.uninspected = [["pid": .number(77), "name": .string("trustd"), "errno": .number(1)]]
        let result = try await run(api, ["t": "environment_status", "components": stage.path])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let load = try XCTUnwrap(result["load"] as? [String: Any])
        XCTAssertEqual(load["complete"] as? Bool, false)
        XCTAssertEqual(try library(load, "libcamfix.dylib")["state"] as? String, "not_mapped")
        XCTAssertFalse(api.methods.contains("environment.install"))
    }

    // MARK: Status, rollback, capabilities, rpc

    func testStatusWithoutComponentsReportsGuestDigestsOnly() async throws {
        let api = EnvironmentDaemonFake()
        let result = try await run(api, ["t": "environment_status"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        let camfix = try library(result["files"], "libcamfix.dylib")
        XCTAssertEqual(camfix["guest"] as? String, "old-libcamfix.dylib")
        XCTAssertNil(camfix["candidate"])
        XCTAssertEqual(api.methods, ["environment.status", "environment.loaded"])
    }

    func testCapabilityGates() async throws {
        let api = EnvironmentDaemonFake()
        api.caps.removeAll { $0 == "environment_transaction" }
        var result = try await update(api)
        XCTAssertEqual(result["code"] as? String, "capability_unavailable")
        XCTAssertEqual(result["capability"] as? String, "environment_transaction")
        XCTAssertTrue(api.calls.isEmpty)
        let none = EnvironmentDaemonFake()
        none.caps = ["session_identity"]
        result = try await run(none, ["t": "environment_status"])
        XCTAssertEqual(result["code"] as? String, "capability_unavailable")
        let executor = VPhoneHostCommandExecutor(apiSession: nil,
                                                 environmentManifest: VPhoneGuestEnvironmentTestSupport.manifestURL)
        let data = await executor.execute(try JSONSerialization.data(withJSONObject: ["t": "environment_update",
                                                                                      "components": stage.path]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String, "api_not_ready")
        let caps = try await run(EnvironmentDaemonFake(), ["t": "capabilities"])
        let commands = try XCTUnwrap(caps["commands"] as? [String: Bool])
        XCTAssertEqual(commands["environment_status"], true)
        XCTAssertEqual(commands["environment_update"], true)
        XCTAssertEqual(commands["environment_rollback"], true)
    }

    func testRollbackNamesTheTransaction() async throws {
        let api = EnvironmentDaemonFake()
        let id = "0000018f2a3b4c5d-1a2b3c4d"
        var result = try await run(api, ["t": "environment_rollback", "transaction": id])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(api.calls.first?.method, "environment.restore")
        XCTAssertEqual(api.calls.first?.params["transaction"], .string(id))
        XCTAssertEqual(result["restored"] as? [String], ["libcamfix.dylib"])
        result = try await run(api, ["t": "environment_rollback", "transaction": "../x"])
        XCTAssertEqual(result["code"] as? String, "invalid_argument")
    }

    func testRPCStillRefusesGuestLibraryReplacement() async throws {
        for method in ["environment.install", "environment.restore"] {
            let api = EnvironmentDaemonFake()
            let result = try await run(api, ["t": "rpc", "method": method, "params": [:] as [String: Any]])
            XCTAssertEqual(result["code"] as? String, "method_not_forwardable", method)
            XCTAssertTrue(api.calls.isEmpty)
        }
        XCTAssertEqual(VPhoneHostRPC.methods["environment.loaded"]?.capability, "environment_activation")
    }

    // MARK: CLI

    func testCLIRequestsAndRestartValidation() throws {
        let update = try VPhoneGuestEnvUpdateCommand.parse(["vm", "--components", "/stage", "--restart", "cameracaptured"])
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: update.request()) as? [String: Any])
        XCTAssertEqual(request["t"] as? String, "environment_update")
        XCTAssertEqual(request["components"] as? String, "/stage")
        XCTAssertEqual(request["restart"] as? [String], ["cameracaptured"])
        XCTAssertThrowsError(try VPhoneGuestEnvUpdateCommand.parse(["vm", "--restart", "SpringBoard"]))
        XCTAssertThrowsError(try VPhoneGuestEnvUpdateCommand.parse(["vm", "--restart", "cameracaptured", "--restart", "launchd"]))
        let relative = try VPhoneGuestEnvUpdateCommand.parse(["vm", "--components", "relative/stage"])
        let relativeRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: relative.request()) as? [String: Any])
        XCTAssertEqual(relativeRequest["components"] as? String,
                       URL(fileURLWithPath: "relative/stage").standardizedFileURL.path)
        let status = try VPhoneGuestEnvStatusCommand.parse(["vm"])
        let statusRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: status.request()) as? [String: Any])
        XCTAssertEqual(statusRequest["t"] as? String, "environment_status")
        XCTAssertNotNil(statusRequest["components"] as? String)
        let rollback = try VPhoneGuestEnvRollbackCommand.parse(["vm", "0000018f2a3b4c5d-1a2b3c4d"])
        let rollbackRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: rollback.request()) as? [String: Any])
        XCTAssertEqual(rollbackRequest["transaction"] as? String, "0000018f2a3b4c5d-1a2b3c4d")
        XCTAssertThrowsError(try VPhoneGuestEnvRollbackCommand.parse(["vm", "../x"]))
    }

    func testSummaryNamesRequiredActionsAndRecovery() async throws {
        let api = EnvironmentDaemonFake()
        current(api, except: ["libvlocation.dylib"])
        api.processes = [55: ("SpringBoard", ["libvlocation.dylib": true]), 310: ("cameracaptured", [:])]
        let result = try await update(api, ["restart": ["cameracaptured"]])
        let lines = VPhoneGuestEnvironmentSummary.lines(result)
        XCTAssertTrue(lines.contains { $0.contains("respring") && $0.contains("not performed") }, "\(lines)")
        XCTAssertTrue(lines.contains("restart: cameracaptured SIGTERM sent to pid(s) 310"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("application behavior: not verified") })
        let failing = EnvironmentDaemonFake()
        current(failing, except: ["libcamfix.dylib", "libvlocation.dylib"])
        failing.failReplacementAt = 0
        let failed = VPhoneGuestEnvironmentSummary.lines(try await update(failing))
        XCTAssertTrue(failed.contains { $0.contains("guest env rollback") }, "\(failed)")
    }
}
