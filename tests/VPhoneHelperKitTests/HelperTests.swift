import Foundation
import Security
import Testing
@testable import VPhoneHelperKit

struct HelperConfigurationTests {
    @Test(arguments: ["", "-", "ABCDE", "abcdefghij", "ABCDEFGHIJ\n", "ABC\" or true", "$(id)"])
    func rejectsUnconfiguredOrInjectedTeam(_ team: String) {
        #expect(throws: (any Error).self) { try VPhoneHelperConfiguration(team: team) }
    }

    @Test func requiresExactMetadataAndCompilableRequirements() throws {
        let configuration = try VPhoneHelperConfiguration(team: "ABCDEFGHIJ")
        var info: [String: Any] = ["VPhoneHelperSigningTeam": configuration.team,
                                  "CFBundleIdentifier": VPhoneHelperIdentity.label,
                                  "CFBundleVersion": VPhoneHelperIdentity.protocolVersion,
                                  "SMAuthorizedClients": configuration.clientRequirements]
        #expect(try VPhoneHelperConfiguration.fromHelperInfo(info).team == configuration.team)
        info["SMAuthorizedClients"] = ["true"]
        #expect(throws: (any Error).self) { try VPhoneHelperConfiguration.fromHelperInfo(info) }
        for text in [configuration.connectionRequirement, configuration.helperRequirement] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        }
        var client: [String: Any] = ["VPhoneHelperSigningTeam": configuration.team, "CFBundleIdentifier": "com.vphone.cli",
            "SMPrivilegedExecutables": [VPhoneHelperIdentity.label: configuration.helperRequirement]]
        #expect(try VPhoneHelperConfiguration.fromClientInfo(client).team == configuration.team)
        client["SMPrivilegedExecutables"] = [VPhoneHelperIdentity.label: "identifier \"com.vphone.cli.helper\""]
        #expect(throws: (any Error).self) { try VPhoneHelperConfiguration.fromClientInfo(client) }
    }

    @Test func unrelatedCodeCannotSatisfyHelperIdentity() throws {
        let configuration = try VPhoneHelperConfiguration(team: "ABCDEFGHIJ")
        #expect(throws: (any Error).self) {
            try VPhoneHelperConfiguration.verifyCode(URL(fileURLWithPath: "/usr/bin/true"), requirement: configuration.helperRequirement)
        }
    }

    @Test func weakenedAuthorizationRulesAreRejected() {
        let valid = VPhoneHelperAuthorization.definition
        #expect(VPhoneHelperAuthorization.ruleIsIntact(valid))
        let mutations: [(String, Any)] = [("class", "allow"), ("group", "staff"), ("authenticate-user", false),
            ("shared", true), ("allow-root", true), ("timeout", 301), ("timeout", -1), ("rule", ["allow"])]
        for (key, value) in mutations {
            var rule = valid
            rule[key] = value
            #expect(!VPhoneHelperAuthorization.ruleIsIntact(rule))
        }
        for key in ["class", "group", "authenticate-user", "shared", "timeout", "allow-root"] {
            var rule = valid
            rule.removeValue(forKey: key)
            #expect(!VPhoneHelperAuthorization.ruleIsIntact(rule))
        }
    }

    @Test(arguments: [0, 1, 31, 33, 1024])
    func malformedExternalFormFailsBeforeAuthorizationDatabaseAccess(_ size: Int) {
        do {
            try VPhoneHelperAuthorization.require(Data(repeating: 0, count: size))
            Issue.record("Malformed form accepted")
        } catch { #expect(error.localizedDescription.contains("lacks a valid administrator authorization form")) }
    }
}

struct HelperServiceTests {
    @Test func xpcRejectsClientWithoutConfiguredSigningIdentity() async throws {
        let delegate = VPhoneHelperListener(configuration: try VPhoneHelperConfiguration(team: "ABCDEFGHIJ"))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VPhoneHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let reply = VPhoneHelperReply<String>()
        let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as? VPhoneHelperProtocol)
        proxy.helperVersion { reply.finish(.success($0)) }
        let outcome = await Task.detached { Result { try reply.wait(timeout: 5) } }.value
        switch outcome {
        case .success: Issue.record("XPC accepted an unrelated signing identity")
        case let .failure(error):
            #expect(!error.localizedDescription.contains("Helper timed out"))
        }
        withExtendedLifetime(delegate) {}
    }

    @Test func unauthorizedRequestCannotInstall() async {
        let service = VPhoneHelperService(authorize: { _ in throw VPhoneHelperError("denied") },
            install: { _, _, _ in Issue.record("Install reached before authorization"); return Data() }, verify: { _ in Data() })
        let pipe = Pipe()
        let result: String? = await withCheckedContinuation { continuation in
            service.installBundle(authorization: Data(), version: "2.0.8", archive: pipe.fileHandleForReading, sha256: "bad") { data, error in
                #expect(data == nil)
                continuation.resume(returning: error)
            }
        }
        #expect(result == "denied")
    }

    @Test func authorizedInstallReturnsReceiptAndForwardsDescriptor() async throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/usr/bin/true"))
        defer { try? input.close() }
        let expected = Data("receipt".utf8)
        let service = VPhoneHelperService(authorize: { #expect($0 == Data([7])) },
            install: { version, archive, digest in
                #expect(version == "2.0.8")
                #expect(archive.fileDescriptor == input.fileDescriptor)
                #expect(digest == "digest")
                return expected
            }, verify: { _ in Data() })
        let result: Data? = await withCheckedContinuation { continuation in
            service.installBundle(authorization: Data([7]), version: "2.0.8", archive: input, sha256: "digest") { data, error in
                #expect(error == nil)
                continuation.resume(returning: data)
            }
        }
        #expect(result == expected)
    }

    @Test func verificationIsReadOnlyAndPropagatesFailure() async {
        let service = VPhoneHelperService(authorize: { _ in Issue.record("Read-only verify asked for authorization") },
            install: { _, _, _ in Issue.record("Read-only verify invoked install"); return Data() },
            verify: { _ in throw VPhoneHelperError("receipt mismatch") })
        let result: String? = await withCheckedContinuation { continuation in
            service.verifyBundle(version: "2.0.8") { data, error in
                #expect(data == nil)
                continuation.resume(returning: error)
            }
        }
        #expect(result == "receipt mismatch")
    }

    @Test func replyCompletesOnlyOnce() throws {
        let reply = VPhoneHelperReply<String>()
        reply.finish(.success("first"))
        reply.finish(.failure(VPhoneHelperError("late invalidation")))
        #expect(try reply.wait(timeout: 0.1) == "first")
    }

    @Test func timeoutIgnoresLateReply() throws {
        let reply = VPhoneHelperReply<String>()
        #expect(throws: (any Error).self) { try reply.wait(timeout: 0.01) }
        reply.finish(.success("late"))
        #expect(throws: (any Error).self) { try reply.wait(timeout: 0.01) }
    }
}
