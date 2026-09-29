import Darwin
import Foundation
import VPhoneBundleStore

final class VPhoneHelperService: NSObject, VPhoneHelperProtocol, @unchecked Sendable {
    // Serial across connections, not one queue per client. Store flock also
    // protects against the direct sudo CLI in another process.
    static let work = DispatchQueue(label: "com.vphone.cli.helper.operations")
    let authorize: @Sendable (Data) throws -> Void
    let install: @Sendable (String, FileHandle, String) throws -> Data
    let verify: @Sendable (String) throws -> Data

    override convenience init() {
        self.init(authorize: VPhoneHelperAuthorization.require,
                  install: { try VPhoneCoreBundleStore().install(version: $0, archive: $1, sha256: $2).encoded() },
                  verify: { try VPhoneCoreBundleStore().verify(version: $0).encoded() })
    }

    init(authorize: @escaping @Sendable (Data) throws -> Void,
         install: @escaping @Sendable (String, FileHandle, String) throws -> Data,
         verify: @escaping @Sendable (String) throws -> Data) {
        self.authorize = authorize
        self.install = install
        self.verify = verify
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) { reply(VPhoneHelperIdentity.protocolVersion) }

    func installBundle(authorization: Data, version: String, archive: FileHandle, sha256: String,
                       reply: @escaping @Sendable (Data?, String?) -> Void) {
        Self.work.async { [self] in
            do {
                try authorize(authorization)
                reply(try install(version, archive, sha256), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func verifyBundle(version: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Self.work.async { [self] in
            do { reply(try verify(version), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
}

public final class VPhoneHelperListener: NSObject, NSXPCListenerDelegate {
    let configuration: VPhoneHelperConfiguration
    public init(configuration: VPhoneHelperConfiguration) { self.configuration = configuration }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(configuration.connectionRequirement)
        connection.exportedInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        connection.exportedObject = VPhoneHelperService()
        connection.resume()
        return true
    }
}

public enum VPhoneHelperDaemon {
    /// Performs no host mutations until metadata, code identity, and UID pass.
    public static func configuration() throws -> VPhoneHelperConfiguration {
        let configuration = try VPhoneHelperConfiguration.fromHelperInfo(Bundle.main.infoDictionary ?? [:])
        guard let executable = Bundle.main.executableURL else { throw VPhoneHelperError("Missing helper executable URL.") }
        try VPhoneHelperConfiguration.verifyCode(executable, requirement: configuration.helperRequirement)
        return configuration
    }

    public static func run() throws -> Never {
        let configuration = try configuration()
        guard geteuid() == 0 else { throw VPhoneHelperError("The signed helper must be started by system launchd as root.") }
        try VPhoneHelperAuthorization.registerRight()
        let delegate = VPhoneHelperListener(configuration: configuration)
        let listener = NSXPCListener(machServiceName: VPhoneHelperIdentity.label)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime((delegate, listener)) { dispatchMain() }
    }
}
