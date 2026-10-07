from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/tests/VPhoneHelperKitTests/OutputXPCTests.swift');s=p.read_text();a='struct OutputXPCTests {';s=s.replace(a,'''private final class OutputTestConnection: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}

'''+a,1);s=s.replace('let output = VPhoneHelperOutputReceiver(operation: operation, writer: nil, onLine: { _ in connection.invalidate() })','let owner = OutputTestConnection(connection)\n        let output = VPhoneHelperOutputReceiver(operation: operation, writer: nil, onLine: { _ in owner.value.invalidate() })');p.write_text(s)
