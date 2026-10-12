import Foundation
import Testing
@testable import VPhoneDaemonWire

struct EnvironmentOperationTests {
    static func wait(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    func context() -> [String: String] {
        var value = Dictionary(uniqueKeysWithValues: EnvironmentOperation.hashes.map { ($0, String(repeating: "a", count: 64)) })
        for key in EnvironmentOperation.identifiers { value[key] = UUID().uuidString }
        value["mode"] = "regular-v2"; value["firmware_generation"] = "fixture-generation"; value["bundle_version"] = "2.6.0-local.1234abcd"
        return value
    }

    @Test func operationRequiresAllBindingsAndJournalPersistsFullCollection() throws {
        let valid = context()
        for key in valid.keys {
            var missing = valid; missing[key] = nil
            #expect(throws: Error.self) { try EnvironmentOperation.validate(missing, daemon: valid["daemon_sha256"]!, instance: valid["daemon_instance"]!) }
        }
        #expect(throws: Error.self) { try EnvironmentOperation.validate(valid, daemon: String(repeating: "b", count: 64), instance: valid["daemon_instance"]!) }
        #expect(throws: Error.self) { try EnvironmentOperation.validate(valid, daemon: valid["daemon_sha256"]!, instance: UUID().uuidString) }
        let guest = try EnvironmentTransactionTests.Guest()
        let entries = try guest.transaction.validate([try guest.stage("libcamfix.dylib", "new")])
        var journal = try guest.transaction.prepare(entries, operation: valid["operation"], context: valid)
        try guest.transaction.apply(&journal, replace: guest.install)
        #expect(journal.rootReadOnly == nil)
        try guest.transaction.finalize(&journal, rootReadOnly: true)
        let stored = try #require(try guest.transaction.journal(id: valid["operation"]!))
        #expect(stored.context == valid)
        #expect(stored.beforeFiles?.count == 5 && stored.afterFiles?.count == 5)
        #expect(stored.rootReadOnly == true)
        #expect(throws: Error.self) { try guest.transaction.prepare(entries, operation: valid["operation"], context: valid) }
    }

    @Test func guestGateExcludesConcurrentWritersWithoutBlockingOrdinaryReads() async throws {
        let gate = GuestMaintenanceGate()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = Task.detached {
            try gate.run(method: "environment.install") {
                entered.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
        }
        let started = await Task.detached { Self.wait(entered) }.value
        #expect(started)
        for method in ["environment.restore", "bootstrap.install", "system.shutdown", "environment.status"] {
            #expect(throws: Error.self) { try gate.run(method: method) { Issue.record("overlapping writer") } }
        }
        #expect(try gate.run(method: "device.info") { 42 } == 42)
        release.signal()
        try await first.value
        try gate.run(method: "system.shutdown") {}
        #expect(throws: Error.self) { try gate.run(method: "environment.install") {} }
    }
}
