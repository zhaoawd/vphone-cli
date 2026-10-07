from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneHelperKitTests/OutputAcknowledgementTests.swift').write_text('''import Foundation
import Testing
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
}
''')
(r/'sources/VPhoneHelperKit/VPhoneHelperOutput.swift').write_text('''import Foundation
final class VPhoneHelperOutputAcknowledgement: @unchecked Sendable {
    func acknowledge(_ success: Bool, _ error: String?) {}
    func fail(_ message: String) {}
    func wait(timeout: TimeInterval = 30) throws {}
}
''')
# Correct the earlier integration script's source names.
p=Path('/private/tmp/vphone-b13-shutdown-integration.py');s=p.read_text().replace('self.guestHaltUnavailable()','self.fallBackFromGuestCommand(vm: vm)').replace('reply.object?["accepted"] == .bool(true)','{ if case let .object(fields) = reply { return fields["accepted"] == .bool(true) }; return false }()');p.write_text(s)
