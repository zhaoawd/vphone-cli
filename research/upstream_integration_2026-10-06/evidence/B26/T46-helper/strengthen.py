from pathlib import Path
import shutil
out=Path('/private/tmp/vphone-b26-t46-helper');p=out/'TransportHarness.swift';shutil.copy2(p,out/'TransportHarness-v2.swift');s=p.read_text()
s=s.replace('private func emit(_ fields: [String: String]) {\n    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])\n    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))\n}', '''private final class Trace: @unchecked Sendable {
    static let shared = Trace()
    let lock = NSLock()
    var values: [[String: String]] = []
    func emit(_ fields: [String: String]) {
        lock.withLock {
            values.append(fields)
            let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
    }
    func snapshot() -> [[String: String]] { lock.withLock { values } }
}
private func emit(_ fields: [String: String]) { Trace.shared.emit(fields) }''')
s=s.replace('''        } else {
            actual.helperDidFinishOutput(operation: operation, reply: reply)
        }
''','''        } else {
            actual.helperDidFinishOutput(operation: operation) { [self] success, error in
                emit(["event": "receiver_finished", "success": String(success), "error": error ?? ""])
                if mode == "writer-failure" {
                    Task {
                        do {
                            try await actual.writer?.finish()
                            emit(["event": "writer_finish_unexpected_success"])
                        } catch {
                            let value = error as NSError
                            let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
                            emit(["event": "writer_finish_error", "domain": value.domain, "code": String(value.code),
                                  "underlying_domain": underlying?.domain ?? "", "underlying_code": underlying.map { String($0.code) } ?? ""])
                        }
                        reply(success, error)
                    }
                } else { reply(success, error) }
            }
        }
''')
s=s.replace('''                writer = VPhoneLogWriter(url: log, handle: try FileHandle(forReadingFrom: log))''','''                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
                let readonly = try FileHandle(forReadingFrom: log)
                let flags = fcntl(readonly.fileDescriptor, F_GETFL)
                guard flags >= 0, flags & O_ACCMODE == O_RDONLY else { throw VPhoneHelperError("Writer fault descriptor was not read-only") }
                emit(["event": "writer_fault_descriptor", "access_mode": "O_RDONLY", "fd": String(readonly.fileDescriptor)])
                writer = VPhoneLogWriter(url: log, handle: readonly)''')
s=s.replace('''            connection.interruptionHandler = { response.finish(.failure(VPhoneHelperError("Transport interrupted"))) }
            connection.invalidationHandler = { response.finish(.failure(VPhoneHelperError("Transport invalidated"))) }''','''            connection.interruptionHandler = { @Sendable in
                emit(["event": "transport_interrupted"])
                response.finish(.failure(VPhoneHelperError("Transport interrupted")))
            }
            connection.invalidationHandler = { @Sendable in
                emit(["event": "transport_invalidated"])
                response.finish(.failure(VPhoneHelperError("Transport invalidated")))
            }''')
s=s.replace('''            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ response.finish(.failure($0)) }) as? VPhoneHelperProtocol else {''','''            let proxyError: @Sendable (Error) -> Void = { error in
                let value = error as NSError
                emit(["event": "transport_proxy_error", "domain": value.domain, "code": String(value.code), "error": error.localizedDescription])
                response.finish(.failure(error))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(proxyError) as? VPhoneHelperProtocol else {''')
s=s.replace('''            if mode == "normal" {''','''            let trace = Trace.shared.snapshot()
            let receiverFinish = trace.first { $0["event"] == "receiver_finished" }
            if mode == "normal" {''')
s=s.replace('''                guard case .success = result, contents ==''','''                guard receiverFinish?["success"] == "true", case .success = result, contents ==''')
s=s.replace('''                    guard elapsed >= 29, elapsed < 40, error.localizedDescription.contains("Helper output not acknowledged") else {''','''                    guard receiverFinish?["success"] == "true", elapsed >= 29, elapsed < 40,
                          error.localizedDescription.contains("Helper output not acknowledged"),
                          error.localizedDescription.contains("Helper timed out") else {''')
s=s.replace('''                if mode == "writer-failure", contents != "preserved\\n" { throw VPhoneHelperError("Read-only failure fixture was changed") }''','''                if mode == "disconnect" {
                    let disconnected = trace.contains { ["transport_invalidated", "transport_interrupted", "transport_proxy_error"].contains($0["event"] ?? "") }
                    guard receiverFinish?["success"] == "true", disconnected, elapsed < 5,
                          !error.localizedDescription.contains("Helper timed out"),
                          !error.localizedDescription.contains("Helper output not acknowledged") else {
                        throw VPhoneHelperError("Expected real transport loss after persisted output was not observed")
                    }
                }
                if mode == "writer-failure" {
                    let storedError = trace.first { $0["event"] == "writer_finish_error" }
                    let badDescriptor = storedError?["domain"] == NSPOSIXErrorDomain && storedError?["code"] == String(EBADF)
                        || storedError?["underlying_domain"] == NSPOSIXErrorDomain && storedError?["underlying_code"] == String(EBADF)
                    guard receiverFinish?["success"] == "false", !(receiverFinish?["error"] ?? "").isEmpty,
                          trace.contains(where: { $0["event"] == "writer_fault_descriptor" }),
                          badDescriptor, elapsed < 5, error.localizedDescription.contains("Helper output not acknowledged"),
                          !error.localizedDescription.contains("Helper timed out"), contents == "preserved\\n" else {
                        throw VPhoneHelperError("Production writer EBADF and negative ACK chain was not observed")
                    }
                }''')
p.write_text(s)
shutil.move(out/'TransportHarness.app',out/'TransportHarness-v2-signed.app');shutil.copy2(out/'sign-readback.json',out/'sign-readback-v2.json')
