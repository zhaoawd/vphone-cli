import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - guest env

/// `vphone-cli guest env status|update|rollback` (T17). Each subcommand
/// sends one host-control request to the running VM, which talks to the API
/// daemon. The JSON response goes to stdout unchanged; a short summary of
/// required actions goes to stderr. Exit status follows `guest send`.
struct VPhoneGuestEnvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Check or update the guest environment libraries of a running VM",
        discussion: """
        Uses the API daemon (VSOCK 1339): start the VM with --api-listen. The
        library list is scripts/guest_environment.json. update replaces only
        libraries that are installed and differ from the candidate stage
        (make guest_components_build), and reports file digests, mapped copies
        per process and required activation separately. It never respings or
        reboots the guest; --restart runs only the listed whitelisted process
        restarts (\(VPhoneGuestEnvironmentUpdater.restartable.joined(separator: ", "))).
        """,
        subcommands: [VPhoneGuestEnvStatusCommand.self, VPhoneGuestEnvUpdateCommand.self,
                      VPhoneGuestEnvRollbackCommand.self]
    )

    static func componentsPath(_ value: String?) -> String {
        guard let value else { return VPhoneResources.resolve().guestComponentsStage.path }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Prints the response and its summary; exit status as `guest send`.
    static func emit(_ request: Data, vm: String, connection: VPhoneGuestConnectionOptions) throws {
        var outcome = VPhoneGuestRequest.perform(request, vm: vm, connection: connection)
        if let stdout = outcome.stdout, let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
            let lines = VPhoneGuestEnvironmentSummary.lines(object)
            if !lines.isEmpty { outcome.stderr = lines.joined(separator: "\n") }
        }
        try outcome.emit()
    }
}

struct VPhoneGuestEnvStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Compare guest libraries with the candidates and report mapped copies")

    @OptionGroup var connection: VPhoneGuestConnectionOptions
    @Argument(help: "VM name") var name: String
    @Option(help: "Candidate stage (default: .build/guest-components-v2/stage)") var components: String?

    func request() throws -> Data {
        try VPhoneGuestEnvCommand.line(["t": "environment_status",
                                        "components": VPhoneGuestEnvCommand.componentsPath(components)])
    }

    func run() throws { try VPhoneGuestEnvCommand.emit(try request(), vm: name, connection: connection) }
}

struct VPhoneGuestEnvUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Replace guest libraries that differ from the candidates")

    @OptionGroup var connection: VPhoneGuestConnectionOptions
    @Argument(help: "VM name") var name: String
    @Option(help: "Candidate stage (default: .build/guest-components-v2/stage)") var components: String?
    @Option(name: .customLong("restart"),
            help: "Restart this process after a complete update (allowed: \(VPhoneGuestEnvironmentUpdater.restartable.joined(separator: ", ")))")
    var restart: [String] = []

    func validate() throws {
        do { _ = try VPhoneGuestEnvironmentUpdater.restartRequest(restart.isEmpty ? nil : restart) } catch let refusal as VPhoneGuestEnvironmentRefusal {
            throw ValidationError(refusal.message)
        }
    }

    func request() throws -> Data {
        var object: [String: Any] = ["t": "environment_update", "components": VPhoneGuestEnvCommand.componentsPath(components)]
        if !restart.isEmpty { object["restart"] = restart }
        return try VPhoneGuestEnvCommand.line(object)
    }

    func run() throws { try VPhoneGuestEnvCommand.emit(try request(), vm: name, connection: connection) }
}

struct VPhoneGuestEnvRollbackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback", abstract: "Copy back the libraries an update transaction replaced")

    @OptionGroup var connection: VPhoneGuestConnectionOptions
    @Argument(help: "VM name") var name: String
    @Argument(help: "Transaction id (environment status: transactions, or an update's recovery record)")
    var transaction: String

    func validate() throws {
        guard !transaction.isEmpty, transaction.count <= 64,
              transaction.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) })
        else { throw ValidationError("transaction must be a transaction id such as 0000018f2a3b4c5d-1a2b3c4d") }
    }

    func request() throws -> Data {
        try VPhoneGuestEnvCommand.line(["t": "environment_rollback", "transaction": transaction])
    }

    func run() throws { try VPhoneGuestEnvCommand.emit(try request(), vm: name, connection: connection) }
}

// MARK: - Summary

/// Plain-text lines for stderr: outcome, file result, load state, the
/// application note, required actions and recovery steps.
enum VPhoneGuestEnvironmentSummary {
    static func lines(_ response: [String: Any]) -> [String] {
        var lines: [String] = []
        if response["ok"] as? Bool != true {
            let code = response["code"] as? String ?? "error"
            lines.append("error: \(code): \(response["error"] as? String ?? "")")
        }
        if let outcome = response["outcome"] as? String { lines.append("outcome: \(outcome)") }
        if let assessment = response["assessment"] as? [String: Any], let state = assessment["state"] as? String {
            let replace = (assessment["replace"] as? [String])?.joined(separator: ", ")
            lines.append("assessment: \(state)" + (replace.map { " (\($0))" } ?? ""))
        }
        for reason in response["reasons"] as? [String] ?? [] { lines.append("reason: \(reason)") }
        if let rows = (response["files"] as? [String: Any])?["libraries"] as? [[String: Any]] {
            var counts: [String: Int] = [:]
            for row in rows { counts[row["result"] as? String ?? "reported", default: 0] += 1 }
            let verified = rows.filter { $0["verified"] as? Bool == true && $0["result"] as? String == "replaced" }.count
            let text = counts.keys.sorted().map { "\(counts[$0]!) \($0)" }.joined(separator: ", ")
            lines.append("files: \(text)" + (counts["replaced"] != nil ? "; \(verified) replaced file(s) match the candidate" : ""))
        }
        if let load = response["load"] as? [String: Any] {
            if load["source"] as? String != "environment.loaded" {
                lines.append("load: unknown (\(load["reason"] as? String ?? "not reported"))")
            } else {
                for row in load["libraries"] as? [[String: Any]] ?? [] where row["state"] as? String == "stale" {
                    let holders = (row["stale"] as? [[String: Any]] ?? []).map { "\($0["name"] ?? "?") (\($0["pid"] ?? "?"))" }
                    lines.append("load: \(row["name"] ?? "?") replaced copy still mapped by \(holders.joined(separator: ", "))")
                }
                if load["complete"] as? Bool == false { lines.append("load: some processes could not be inspected; the result is partial") }
            }
        }
        if response["application"] != nil { lines.append("application behavior: not verified") }
        if let activation = response["activation"] as? [String: Any] {
            for action in activation["actions"] as? [[String: Any]] ?? [] {
                let pid = action["pid"].map { " pid \($0)" } ?? ""
                let state = action["executed"] as? Bool == true ? "done" : "action required"
                lines.append("\(state): \(action["action"] ?? "?") \(action["process"] ?? "?")\(pid): "
                             + "\(action["reason"] ?? ""); \(action["executed"] as? Bool == true ? "performed by --restart" : action["how"] ?? "")")
            }
            for run in activation["executed"] as? [[String: Any]] ?? [] {
                let process = run["process"] as? String ?? "?"
                if let error = run["error"] {
                    lines.append("restart: \(process) failed (\(error))")
                } else {
                    let pids = (run["pids"] as? [Any] ?? []).map { "\($0)" }
                    lines.append("restart: \(process) SIGTERM sent to pid(s) "
                                 + (pids.isEmpty ? "none (not running)" : pids.joined(separator: ", ")))
                }
            }
        }
        if let recovery = response["recovery"] as? [String: Any] {
            for step in recovery["steps"] as? [String] ?? [] { lines.append("recovery: \(step)") }
        }
        return lines
    }
}
