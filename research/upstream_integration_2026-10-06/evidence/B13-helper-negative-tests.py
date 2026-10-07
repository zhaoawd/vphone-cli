from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneHelperKitTests/OutputAcknowledgementTests.swift';s=p.read_text();i=s.rfind('\n}')
s=s[:i]+'''
    @Test func defaultMissingAcknowledgementWaitsThirtySecondsThenFails() async throws {
        let result = await Task.detached {
            let started = Date()
            do { try VPhoneHelperOutputAcknowledgement().wait(); return (Date().timeIntervalSince(started), false) }
            catch { return (Date().timeIntervalSince(started), true) }
        }.value
        #expect(result.1)
        #expect(result.0 >= 29)
        #expect(result.0 < 40)
    }
''' +s[i:];p.write_text(s)
p=r/'tests/VPhoneHelperKitTests/OutputXPCTests.swift';s=p.read_text();i=s.rfind('\n}')
s=s[:i]+'''
    @Test func clientDisconnectBeforeAcknowledgementCannotReturnSuccess() async throws {
        let delegate = OutputTestListener()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate; listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let operation = UUID().uuidString
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        let output = VPhoneHelperOutputReceiver(operation: operation, writer: nil, onLine: { _ in connection.invalidate() })
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
''' +s[i:];p.write_text(s)
