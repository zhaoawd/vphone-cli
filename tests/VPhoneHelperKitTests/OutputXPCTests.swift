import Foundation
import Testing
import VPhoneCore
@testable import VPhoneHelperKit

private final class OutputTestListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = VPhoneHelperService(authorize: { _ in throw VPhoneHelperError("No mutations in transport test") },
                                         install: { _, _, _ in Data() }, verify: { Data($0.utf8) })
        service.connection = connection
        connection.exportedInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class OutputTestConnection: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}

struct OutputXPCTests {
    /// Anonymous local XPC tests the actual wire/order without registering a
    /// privileged service or substituting for its code-identity checks.
    @Test func twoConnectionsReceiveOnlyTheirOwnPersistedOutputBeforeReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = OutputTestListener()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        for version in ["2.6.1-local.ab12cd34", "2.6.2-ci.ab12cd34"] {
            let operation = UUID().uuidString
            let url = directory.appendingPathComponent(operation + ".log")
            let output = VPhoneHelperOutputReceiver(operation: operation, writer: try VPhoneLogWriter(url: url), onLine: { _ in })
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
            connection.exportedObject = output
            connection.resume()
            defer { connection.invalidate() }
            let response = VPhoneHelperReply<Data>()
            let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { response.finish(.failure($0)) } as? VPhoneHelperProtocol)
            proxy.verifyBundleStreaming(version: version, operation: operation) { data, error in
                if let error { response.finish(.failure(VPhoneHelperError(error))) }
                else if let data { response.finish(.success(data)) }
                else { response.finish(.failure(VPhoneHelperError("Missing response"))) }
            }
            let result = try await Task.detached { try response.wait(timeout: 40) }.value
            #expect(result == Data(version.utf8))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == "Verifying Core Bundle \(version)\nCore Bundle operation completed\n")
        }
    }
    @Test func clientDisconnectBeforeAcknowledgementCannotReturnSuccess() async throws {
        let delegate = OutputTestListener()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate; listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let operation = UUID().uuidString
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let owner = OutputTestConnection(connection)
        let output = VPhoneHelperOutputReceiver(operation: operation, writer: nil, onLine: { _ in owner.value.invalidate() })
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
        connection.exportedObject = output; connection.resume()
        defer { connection.invalidate() }
        let response = VPhoneHelperReply<Data>()
        let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { response.finish(.failure($0)) } as? VPhoneHelperProtocol)
        proxy.verifyBundleStreaming(version: "2.6.1-local.ab12cd34", operation: operation) { data, error in
            if let error { response.finish(.failure(VPhoneHelperError(error))) }
            else if let data { response.finish(.success(data)) }
            else { response.finish(.failure(VPhoneHelperError("Missing response"))) }
        }
        let failed = await Task.detached {
            do { _ = try response.wait(timeout: 40); return false }
            catch { return true }
        }.value
        #expect(failed)
    }

}
