import Foundation
@objc(VPhoneHelperProtocol) protocol ProbeProtocol {
    func helperVersion(reply: @escaping (String) -> Void)
}
final class ResultBox: @unchecked Sendable {
    let lock = NSLock(); let done = DispatchSemaphore(value: 0)
    var value: String?
    func finish(_ text: String) { lock.lock(); defer { lock.unlock() }; if value == nil { value = text; done.signal() } }
}
let result = ResultBox()
let connection = NSXPCConnection(machServiceName: "com.vphone.cli.helper", options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
connection.interruptionHandler = { result.finish("connection interrupted") }
connection.invalidationHandler = { result.finish("connection invalidated") }
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in result.finish("transport error: \(error)") } as! ProbeProtocol
proxy.helperVersion { result.finish("UNEXPECTED accepted protocol \($0)") }
let wait = result.done.wait(timeout: .now() + 8)
connection.invalidate()
print(wait == .timedOut ? "timeout; rejection not proven" : result.value!)
exit(wait == .timedOut || result.value!.hasPrefix("UNEXPECTED") ? 1 : 0)
