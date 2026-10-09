import Foundation
import VPhoneCore

@objc(VPhoneHelperOutputProtocol)
public protocol VPhoneHelperOutputProtocol {
    func helperDidEmit(operation: String, line: String)
    func helperDidFinishOutput(operation: String, reply: @escaping @Sendable (Bool, String?) -> Void)
}

final class VPhoneHelperOutputAcknowledgement: @unchecked Sendable {
    private let reply = VPhoneHelperReply<Bool>()
    func acknowledge(_ success: Bool, _ error: String?) {
        if success && error == nil { reply.finish(.success(true)) }
        else { fail(error ?? "Client did not persist helper output") }
    }
    func fail(_ message: String) { reply.finish(.failure(VPhoneHelperError(message))) }
    func wait(timeout: TimeInterval = 30) throws {
        do { _ = try reply.wait(timeout: timeout) }
        catch { throw VPhoneHelperError("Helper output not acknowledged: \(error.localizedDescription). The operation may have committed; verify before retrying.") }
    }
}

/// One exported object per request connection. The UUID cannot be reused by a
/// second operation; queued callbacks finish before the writer acknowledges.
final class VPhoneHelperOutputReceiver: NSObject, VPhoneHelperOutputProtocol, @unchecked Sendable {
    let operation: String
    let writer: VPhoneLogWriter?
    let onLine: @Sendable (String) throws -> Void
    private let queue = DispatchQueue(label: "com.vphone.cli.helper.output")
    private var failure: String?
    private var sealed = false

    init(operation: String, writer: VPhoneLogWriter?, onLine: @escaping @Sendable (String) throws -> Void) {
        self.operation = operation; self.writer = writer; self.onLine = onLine
    }

    func helperDidEmit(operation: String, line: String) {
        queue.async { [self] in
            guard operation == self.operation, !sealed else {
                failure = failure ?? "Mismatched or late helper output"
                return
            }
            writer?.write(line)
            do { try onLine(line) } catch { failure = failure ?? error.localizedDescription }
        }
    }

    func helperDidFinishOutput(operation: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async { [self] in
            guard operation == self.operation, !sealed else { reply(false, "Mismatched or repeated output completion"); return }
            sealed = true
            let priorFailure = failure
            Task { [writer] in
                do {
                    try await writer?.finish()
                    reply(priorFailure == nil, priorFailure)
                } catch { reply(false, error.localizedDescription) }
            }
        }
    }
}

/// Bound to the operation's connection and UUID. Transport errors complete the
/// same acknowledgement as the reply, so a late ACK cannot mask a disconnect.
final class VPhoneHelperOutputChannel: @unchecked Sendable {
    let operation: String
    let acknowledgement = VPhoneHelperOutputAcknowledgement()
    let proxy: VPhoneHelperOutputProtocol?
    init(connection: NSXPCConnection, operation: String) {
        self.operation = operation
        let acknowledgement = self.acknowledgement
        proxy = connection.remoteObjectProxyWithErrorHandler { acknowledgement.fail($0.localizedDescription) } as? VPhoneHelperOutputProtocol
        if proxy == nil { acknowledgement.fail("Helper output client unavailable") }
    }
    func emit(_ line: String) { proxy?.helperDidEmit(operation: operation, line: line) }
    func finish() throws {
        proxy?.helperDidFinishOutput(operation: operation) { [acknowledgement] success, error in
            acknowledgement.acknowledge(success, error)
        }
        try acknowledgement.wait()
    }
}
