// Prepared only: not compiled, signed, or run. Transport-layer acceptance only.
// Build as a client app plus its application-scoped embedded XPCService, with
// -package-name vphone_cli, importing frozen -enable-testing production modules.
import Darwin
import Foundation
import Security
import VPhoneCore
@testable import VPhoneHelperKit

private let clientID = "com.vphone.acceptance.t46.client"
private let serviceID = "com.vphone.acceptance.t46.service"
private let team = "3AA3QL69MQ"
private func requirement(_ id: String) -> String {
    "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
}
private func emit(_ fields: [String: String]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}
private func audit(_ connection: NSXPCConnection) -> Data? {
    guard connection.responds(to: NSSelectorFromString("auditToken")),
          let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
    var token = audit_token_t()
    value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
    return withUnsafeBytes(of: &token) { Data($0) }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let expected = requirement(clientID)
        if let reason = VPhoneHelperListener.callerRejection(auditToken: audit(connection),
             pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier, requirement: expected) {
            emit(["event": "identity_refused", "reason": reason]); return false
        }
        connection.setCodeSigningRequirement(expected)
        let service = VPhoneHelperService(
            authorize: { _ in throw VPhoneHelperError("Transport harness never authorizes installation") },
            install: { _, _, _ in throw VPhoneHelperError("Transport harness never installs") },
            verify: { version in Data("transport-only:\(version):server-pid=\(getpid())".utf8) })
        service.connection = connection
        connection.exportedInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class Receiver: NSObject, VPhoneHelperOutputProtocol, @unchecked Sendable {
    let actual: VPhoneHelperOutputReceiver
    let mode: String
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var heldReplies: [@Sendable (Bool, String?) -> Void] = []
    init(actual: VPhoneHelperOutputReceiver, mode: String, connection: NSXPCConnection) {
        self.actual = actual; self.mode = mode; self.connection = connection
    }
    func helperDidEmit(operation: String, line: String) {
        actual.helperDidEmit(operation: operation, line: line)
    }
    func helperDidFinishOutput(operation: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        if mode == "missing-ack" || mode == "disconnect" {
            // Retain the actual XPC reply block; persistence finishes, then the
            // fault withholds the ACK or invalidates this exact connection.
            lock.withLock { heldReplies.append(reply) }
            actual.helperDidFinishOutput(operation: operation) { [self] success, error in
                emit(["event": "receiver_finished", "success": String(success), "error": error ?? ""])
                if mode == "disconnect" { connection.invalidate() }
            }
        } else {
            actual.helperDidFinishOutput(operation: operation, reply: reply)
        }
    }
}

@main private struct Harness {
    nonisolated static func main() {
        do {
            let isService = Bundle.main.infoDictionary?["B26HarnessRole"] as? String == "service"
            let ownID = isService ? serviceID : clientID
            try VPhoneHelperConfiguration.verifyCode(Bundle.main.bundleURL, requirement: requirement(ownID))
            if isService {
                let listener = NSXPCListener.service()
                let delegate = Listener(); listener.delegate = delegate
                withExtendedLifetime(delegate) { listener.resume(); dispatchMain() }
            }
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2, ["normal", "missing-ack", "disconnect", "writer-failure"].contains(args[0]) else {
                throw VPhoneHelperError("Usage: TransportHarness <normal|missing-ack|disconnect|writer-failure> <new-output-directory>")
            }
            let mode = args[0], directory = URL(fileURLWithPath: args[1], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw VPhoneHelperError("Output directory must be new") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let operation = UUID().uuidString, log = directory.appendingPathComponent(operation + ".log")
            let writer: VPhoneLogWriter
            if mode == "writer-failure" {
                // Real FileHandle I/O failure through the production writer's
                // package-only initializer. This is a deterministic read-only
                // descriptor fault, not a claim about disk-full behavior.
                try Data("preserved\n".utf8).write(to: log, options: [.withoutOverwriting])
                writer = VPhoneLogWriter(url: log, handle: try FileHandle(forReadingFrom: log))
            } else { writer = try VPhoneLogWriter(url: log) }
            let connection = NSXPCConnection(serviceName: serviceID)
            connection.setCodeSigningRequirement(requirement(serviceID))
            connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
            let actual = VPhoneHelperOutputReceiver(operation: operation, writer: writer, onLine: { _ in })
            let receiver = Receiver(actual: actual, mode: mode, connection: connection)
            connection.exportedObject = receiver
            let response = VPhoneHelperReply<Data>()
            connection.interruptionHandler = { response.finish(.failure(VPhoneHelperError("Transport interrupted"))) }
            connection.invalidationHandler = { response.finish(.failure(VPhoneHelperError("Transport invalidated"))) }
            connection.resume()
            defer { connection.invalidate(); withExtendedLifetime(receiver) {} }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ response.finish(.failure($0)) }) as? VPhoneHelperProtocol else {
                throw VPhoneHelperError("Missing typed remote proxy")
            }
            let versionReply = VPhoneHelperReply<String>()
            proxy.helperVersion { versionReply.finish(.success($0)) }
            guard try versionReply.wait(timeout: 5) == VPhoneHelperIdentity.protocolVersion else {
                throw VPhoneHelperError("Unexpected production service protocol")
            }
            let servicePID = connection.processIdentifier
            guard servicePID > 0, servicePID != getpid() else { throw VPhoneHelperError("Distinct peer PID not observed after handshake") }
            emit(["event": "authenticated_handshake", "client_pid": String(getpid()), "service_pid": String(servicePID)])
            let started = ProcessInfo.processInfo.systemUptime
            proxy.verifyBundleStreaming(version: "2.6.1-local.ab12cd34", operation: operation) { data, error in
                if let error { response.finish(.failure(VPhoneHelperError(error))) }
                else if let data { response.finish(.success(data)) }
                else { response.finish(.failure(VPhoneHelperError("Missing response"))) }
            }
            let result = Result { try response.wait(timeout: 40) }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let contents = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            var fields = ["mode": mode, "client_pid": String(getpid()), "service_pid": String(servicePID),
                          "elapsed_seconds": String(elapsed), "operation": operation, "log": log.path,
                          "log_bytes": String(contents.utf8.count)]
            switch result {
            case let .success(data): fields["result"] = "success"; fields["data"] = String(decoding: data, as: UTF8.self)
            case let .failure(error): fields["result"] = "failure"; fields["error"] = error.localizedDescription
            }
            emit(fields)
            guard servicePID > 0, servicePID != getpid() else { throw VPhoneHelperError("Distinct live peer PID was not observed") }
            if mode == "normal" {
                guard case .success = result, contents == "Verifying Core Bundle 2.6.1-local.ab12cd34\nCore Bundle operation completed\n" else {
                    throw VPhoneHelperError("Normal transport/log comparison failed")
                }
            } else {
                guard case let .failure(error) = result else { throw VPhoneHelperError("Fault returned success") }
                if mode == "missing-ack" {
                    guard elapsed >= 29, elapsed < 40, error.localizedDescription.contains("Helper output not acknowledged") else {
                        throw VPhoneHelperError("Production ACK timeout boundary was not observed")
                    }
                }
                if mode == "writer-failure", contents != "preserved\n" { throw VPhoneHelperError("Read-only failure fixture was changed") }
            }
        } catch {
            emit(["event": "harness_failure", "error": error.localizedDescription]); exit(1)
        }
    }
}
