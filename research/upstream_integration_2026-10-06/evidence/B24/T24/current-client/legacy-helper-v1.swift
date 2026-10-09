// Controlled legacy-protocol sample. This is an acceptance fixture, not a
// historical v1 helper binary and not the production helper implementation.
import Darwin
import Foundation

@objc(VPhoneHelperProtocol)
protocol LegacyHelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void)
    func installBundle(authorization: Data, version: String, archive: FileHandle, sha256: String,
                       reply: @escaping (Data?, String?) -> Void)
    func verifyBundle(version: String, reply: @escaping (Data?, String?) -> Void)
}

final class Service: NSObject, LegacyHelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void) {
        FileHandle.standardError.write(Data("fixture: helperVersion -> 1\n".utf8))
        reply("1")
    }
    func installBundle(authorization: Data, version: String, archive: FileHandle, sha256: String,
                       reply: @escaping (Data?, String?) -> Void) {
        FileHandle.standardError.write(Data("FIXTURE_FORBIDDEN_OPERATION: installBundle\n".utf8))
        reply(nil, "Controlled fixture never installs bundles")
    }
    func verifyBundle(version: String, reply: @escaping (Data?, String?) -> Void) {
        FileHandle.standardError.write(Data("FIXTURE_FORBIDDEN_OPERATION: verifyBundle\n".utf8))
        reply(nil, "Controlled fixture never verifies bundles")
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        FileHandle.standardError.write(Data("fixture: accepted pid=\(connection.processIdentifier) uid=\(connection.effectiveUserIdentifier)\n".utf8))
        connection.exportedInterface = NSXPCInterface(with: LegacyHelperProtocol.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

// The parent acceptance runner controls the launchd domain, signing identity,
// paths and lifecycle. This fixture exposes no executable or shell operation.
let listener = NSXPCListener(machServiceName: "com.vphone.cli.helper")
let delegate = Listener()
listener.delegate = delegate
listener.resume()
withExtendedLifetime((listener, delegate)) { dispatchMain() }
