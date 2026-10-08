import Foundation
import Testing
import VPhoneCore
@testable import VPhoneHelperKit

struct OutputAcknowledgementTests {
    @Test func missingAcknowledgementDoesNotReturnSuccess() {
        let acknowledgement = VPhoneHelperOutputAcknowledgement()
        #expect(throws: (any Error).self) { try acknowledgement.wait(timeout: 0.01) }
    }
    @Test func disconnectOrWriterFailureCannotBeTurnedIntoSuccessByLateAck() {
        let acknowledgement = VPhoneHelperOutputAcknowledgement()
        acknowledgement.fail("writer failed")
        acknowledgement.acknowledge(true, nil)
        #expect(throws: (any Error).self) { try acknowledgement.wait(timeout: 0.01) }
    }
    @Test func successfulAckPermitsCompletion() throws {
        let acknowledgement = VPhoneHelperOutputAcknowledgement()
        acknowledgement.acknowledge(true, nil)
        try acknowledgement.wait(timeout: 0.01)
    }
    @Test func receiverAcknowledgesOnlyAfterFullLogIsPersistedAndRejectsOtherOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation = UUID().uuidString
        let url = directory.appendingPathComponent("operation.log")
        let writer = try VPhoneLogWriter(url: url)
        let receiver = VPhoneHelperOutputReceiver(operation: operation, writer: writer, onLine: { _ in })
        for index in 0..<10000 { receiver.helperDidEmit(operation: operation, line: "line \(index)") }
        receiver.helperDidEmit(operation: operation, line: "panic: final tail")
        let result: Bool = await withCheckedContinuation { continuation in
            receiver.helperDidFinishOutput(operation: operation) { success, error in
                #expect(error == nil)
                continuation.resume(returning: success)
            }
        }
        #expect(result)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 10001)
        #expect(lines.first == "line 0")
        #expect(lines.last == "panic: final tail")
        let other: Bool = await withCheckedContinuation { continuation in
            receiver.helperDidFinishOutput(operation: UUID().uuidString) { success, _ in continuation.resume(returning: success) }
        }
        #expect(!other)
    }

    @Test func defaultMissingAcknowledgementWaitsThirtySecondsThenFails() async throws {
        let result = try await onHelperTestThread {
            let started = Date()
            do { try VPhoneHelperOutputAcknowledgement().wait(); return (Date().timeIntervalSince(started), false) }
            catch { return (Date().timeIntervalSince(started), true) }
        }
        #expect(result.1)
        #expect(result.0 >= 29)
        #expect(result.0 < 40)
    }

}
