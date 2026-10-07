import Foundation
import Security
import ServiceManagement
import VPhoneCore

/// Synchronous client for CLI/background UI workers. Never call blocking
/// operations from a UI actor. Each request owns and closes its XPC connection.
public final class VPhoneHelperClient: @unchecked Sendable {
    let configuration: VPhoneHelperConfiguration
    let bundle: Bundle
    private let authorizationLock = NSLock()
    private var authorization: AuthorizationRef?

    public init(bundle: Bundle = .main) throws {
        self.bundle = bundle
        configuration = try VPhoneHelperConfiguration.fromClientInfo(bundle.infoDictionary ?? [:])
        let identifier = bundle.bundleIdentifier ?? ""
        try VPhoneHelperConfiguration.verifyCode(bundle.bundleURL,
            requirement: VPhoneHelperConfiguration.requirement(identifier: identifier, team: configuration.team))
    }

    deinit { if let authorization { AuthorizationFree(authorization, []) } }

    public func version() throws -> String {
        try request(timeout: 5) { proxy, reply in proxy.helperVersion { reply(.success($0)) } }
    }

    public func verifyBundle(version: String, logFile: URL? = nil) throws -> Data {
        try requireVersion()
        let output = try outputReceiver(logFile: logFile)
        return try request(timeout: 300, output: output) { proxy, reply in
            proxy.verifyBundleStreaming(version: version, operation: output.operation) { data, error in Self.finish(data, error, reply) }
        }
    }

    public func installBundle(version: String, archive: FileHandle, sha256: String, logFile: URL? = nil) throws -> Data {
        try requireVersion()
        let form = try externalForm()
        let output = try outputReceiver(logFile: logFile)
        return try request(timeout: 1800, output: output) { proxy, reply in
            proxy.installBundleStreaming(authorization: form, version: version, archive: archive, sha256: sha256, operation: output.operation) { data, error in
                Self.finish(data, error, reply)
            }
        }
    }

    private func requireVersion() throws {
        guard try version() == VPhoneHelperIdentity.protocolVersion else {
            throw VPhoneHelperError("Installed helper protocol differs from this client. Register the matching signed helper.")
        }
    }

    // MARK: - Registration

    public func register() throws {
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(VPhoneHelperIdentity.label)")
        guard let info = CFBundleCopyInfoDictionaryForURL(helper as CFURL) as? [String: Any],
              try VPhoneHelperConfiguration.fromHelperInfo(info).team == configuration.team else {
            throw VPhoneHelperError("Bundled helper metadata is missing or mismatched.")
        }
        try VPhoneHelperConfiguration.verifyCode(helper, requirement: configuration.helperRequirement)
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            throw VPhoneHelperError("Unable to create administrator authorization.")
        }
        defer { AuthorizationFree(reference, []) }
        try VPhoneHelperAuthorization.obtainRight(kSMRightBlessPrivilegedHelper, reference: reference)
        typealias Bless = @convention(c) (CFString, CFString, AuthorizationRef,
            UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        guard let library = dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_LAZY) else {
            throw VPhoneHelperError("ServiceManagement is unavailable.")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SMJobBless") else { throw VPhoneHelperError("SMJobBless is unavailable.") }
        let bless = unsafeBitCast(symbol, to: Bless.self)
        var error: Unmanaged<CFError>?
        let success = bless(kSMDomainSystemLaunchd, VPhoneHelperIdentity.label as CFString, reference, &error)
        let detail = error?.takeRetainedValue()
        guard success.boolValue else {
            throw VPhoneHelperError("Helper registration failed: \(detail.map { String(describing: $0) } ?? "unknown error")")
        }
        try requireVersion()
        let installed = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(VPhoneHelperIdentity.label)")
        try VPhoneHelperConfiguration.verifyCode(installed, requirement: configuration.helperRequirement)
        guard try Data(contentsOf: installed) == Data(contentsOf: helper) else {
            throw VPhoneHelperError("Installed helper differs from the bundled executable.")
        }
    }

    // MARK: - Authorization and transport

    private func externalForm() throws -> Data {
        try authorizationLock.withLock {
            if authorization == nil {
                var reference: AuthorizationRef?
                guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
                    throw VPhoneHelperError("Unable to create administrator authorization.")
                }
                authorization = reference
            }
            let reference = authorization!
            // Refuse a weakened rule before asking the user to authorize it.
            try VPhoneHelperAuthorization.requireIntactRule()
            try VPhoneHelperAuthorization.obtainRight(VPhoneHelperIdentity.privilegedRight, reference: reference)
            var form = AuthorizationExternalForm()
            guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else {
                throw VPhoneHelperError("Unable to encode administrator authorization.")
            }
            return withUnsafeBytes(of: form.bytes) { Data($0) }
        }
    }

    private func outputReceiver(logFile: URL?) throws -> VPhoneHelperOutputReceiver {
        try VPhoneHelperOutputReceiver(operation: UUID().uuidString,
            writer: logFile.map { try VPhoneLogWriter(url: $0) }, onLine: { line in
                try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
            })
    }

    private func request<T: Sendable>(timeout: TimeInterval, output: VPhoneHelperOutputReceiver? = nil,
        _ body: (VPhoneHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) throws -> T {
        let reply = VPhoneHelperReply<T>()
        let connection = NSXPCConnection(machServiceName: VPhoneHelperIdentity.label, options: .privileged)
        connection.setCodeSigningRequirement(configuration.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        if let output {
            connection.exportedInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
            connection.exportedObject = output
        }
        connection.interruptionHandler = { reply.finish(.failure(VPhoneHelperError("Helper connection interrupted; an install may still be running. Verify before retrying."))) }
        connection.invalidationHandler = { reply.finish(.failure(VPhoneHelperError("Helper connection invalidated; an install may still be running. Verify before retrying."))) }
        connection.resume()
        defer { connection.invalidate() }
        let object = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) }
        guard let proxy = object as? VPhoneHelperProtocol else { throw VPhoneHelperError("Unable to connect to the helper.") }
        body(proxy) { reply.finish($0) }
        return try reply.wait(timeout: timeout)
    }

    private static func finish(_ data: Data?, _ error: String?, _ reply: @Sendable (Result<Data, Error>) -> Void) {
        if let error { reply(.failure(VPhoneHelperError(error))) }
        else if let data { reply(.success(data)) }
        else { reply(.failure(VPhoneHelperError("Helper returned an empty response."))) }
    }
}

final class VPhoneHelperReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    func finish(_ result: Result<T, Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
            semaphore.signal()
        }
    }
    func wait(timeout: TimeInterval) throws -> T {
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(VPhoneHelperError("Helper timed out; an install may still be running. Verify before retrying.")))
        }
        return try lock.withLock { try result!.get() }
    }
}
