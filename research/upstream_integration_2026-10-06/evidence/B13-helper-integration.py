from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'Package.swift';s=p.read_text().replace('name: "VPhoneHelperKit", dependencies: ["VPhoneBundleStore"]','name: "VPhoneHelperKit", dependencies: ["VPhoneBundleStore", "VPhoneLaunchpadKit"]');p.write_text(s)
p=r/'sources/VPhoneHelperKit/VPhoneHelperProtocol.swift';s=p.read_text().replace('protocolVersion = "1"','protocolVersion = "2"');needle='    func helperVersion(reply:';i=s.index(needle);s=s[:i]+'''    func installBundleStreaming(authorization: Data, version: String, archive: FileHandle, sha256: String,
                                operation: String, reply: @escaping @Sendable (Data?, String?) -> Void)
    func verifyBundleStreaming(version: String, operation: String, reply: @escaping @Sendable (Data?, String?) -> Void)
'''+s[i:];p.write_text(s)
p=r/'sources/VPhoneHelperKit/VPhoneHelperService.swift';s=p.read_text().replace('    let authorize:','    weak var connection: NSXPCConnection?\n    let authorize:',1);i=s.index('    func helperVersion');s=s[:i]+'''    func installBundleStreaming(authorization: Data, version: String, archive: FileHandle, sha256: String,
                                operation: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        streaming(operation: operation, reply: reply) { [self] output in
            try authorize(authorization)
            try VPhoneBundleVersion.require(version)
            output.emit("Installing Core Bundle \\(version)")
            return try install(version, archive, sha256)
        }
    }

    func verifyBundleStreaming(version: String, operation: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        streaming(operation: operation, reply: reply) { [self] output in
            try VPhoneBundleVersion.require(version)
            output.emit("Verifying Core Bundle \\(version)")
            return try verify(version)
        }
    }

    private func streaming(operation: String, reply: @escaping @Sendable (Data?, String?) -> Void,
                           body: @escaping @Sendable (VPhoneHelperOutputChannel) throws -> Data) {
        guard UUID(uuidString: operation) != nil, let connection else {
            reply(nil, "Helper output requires an operation UUID and a live connection")
            return
        }
        let output = VPhoneHelperOutputChannel(connection: connection, operation: operation)
        Self.work.async {
            let result = Result { try body(output) }
            output.emit(result.failureMessage ?? "Core Bundle operation completed")
            do { try output.finish() }
            catch { reply(nil, error.localizedDescription); return }
            switch result {
            case let .success(data): reply(data, nil)
            case let .failure(error): reply(nil, error.localizedDescription)
            }
        }
    }

'''+s[i:];s=s.replace('connection.exportedObject = VPhoneHelperService()','''let service = VPhoneHelperService()
        service.connection = connection
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)''');s += '''\nprivate extension Result where Success == Data, Failure == Error {
    var failureMessage: String? { if case let .failure(error) = self { return error.localizedDescription }; return nil }
}
''';p.write_text(s)
p=r/'sources/VPhoneHelperKit/VPhoneHelperClient.swift';s=p.read_text().replace('import ServiceManagement','import ServiceManagement\nimport VPhoneLaunchpadKit')
s=s.replace('public func verifyBundle(version: String) throws -> Data {','public func verifyBundle(version: String, logFile: URL? = nil) throws -> Data {');s=s.replace('public func installBundle(version: String, archive: FileHandle, sha256: String) throws -> Data {','public func installBundle(version: String, archive: FileHandle, sha256: String, logFile: URL? = nil) throws -> Data {')
s=s.replace('return try request(timeout: 300) { proxy, reply in\n            proxy.verifyBundle(version: version)', '''let output = try outputReceiver(logFile: logFile)
        return try request(timeout: 300, output: output) { proxy, reply in
            proxy.verifyBundleStreaming(version: version, operation: output.operation)''')
s=s.replace('return try request(timeout: 1800) { proxy, reply in\n            proxy.installBundle(authorization: form, version: version, archive: archive, sha256: sha256)', '''let output = try outputReceiver(logFile: logFile)
        return try request(timeout: 1800, output: output) { proxy, reply in
            proxy.installBundleStreaming(authorization: form, version: version, archive: archive, sha256: sha256, operation: output.operation)''')
s=s.replace('    private func request<T: Sendable>(timeout: TimeInterval,','''    private func outputReceiver(logFile: URL?) throws -> VPhoneHelperOutputReceiver {
        try VPhoneHelperOutputReceiver(operation: UUID().uuidString,
            writer: logFile.map { try VPhoneLaunchpadLogWriter(url: $0) }, onLine: { line in
                try FileHandle.standardError.write(contentsOf: Data((line + "\\n").utf8))
            })
    }

    private func request<T: Sendable>(timeout: TimeInterval, output: VPhoneHelperOutputReceiver? = nil,''')
s=s.replace('        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)','''        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        if let output {
            connection.exportedInterface = NSXPCInterface(with: VPhoneHelperOutputProtocol.self)
            connection.exportedObject = output
        }''');p.write_text(s)
p=r/'scripts/build_helper_candidate.sh';s=p.read_text().replace("'CFBundleVersion': '1'","'CFBundleVersion': '2'");p.write_text(s)
