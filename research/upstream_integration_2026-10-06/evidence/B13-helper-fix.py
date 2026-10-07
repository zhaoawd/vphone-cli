from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneHelperKit/VPhoneHelperService.swift';s=p.read_text().replace('import VPhoneBundleStore','import VPhoneBundleStore\nimport VPhoneLaunchpadKit').replace('            try VPhoneBundleVersion.require(version)','            guard VPhoneLaunchpadCoreBundleVersion.isStoreName(version) else { throw VPhoneHelperError("Invalid Core Bundle version") }');p.write_text(s)
p=r/'tests/VPhoneHelperKitTests/OutputAcknowledgementTests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func receiverAcknowledgesOnlyAfterFullLogIsPersistedAndRejectsOtherOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation = UUID().uuidString
        let url = directory.appendingPathComponent("operation.log")
        let writer = try VPhoneLaunchpadLogWriter(url: url)
        let receiver = VPhoneHelperOutputReceiver(operation: operation, writer: writer, onLine: { _ in })
        for index in 0..<10000 { receiver.helperDidEmit(operation: operation, line: "line \\(index)") }
        receiver.helperDidEmit(operation: operation, line: "panic: final tail")
        let result: Bool = await withCheckedContinuation { continuation in
            receiver.helperDidFinishOutput(operation: operation) { success, error in
                #expect(error == nil)
                continuation.resume(returning: success)
            }
        }
        #expect(result)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\\n")
        #expect(lines.count == 10001)
        #expect(lines.first == "line 0")
        #expect(lines.last == "panic: final tail")
        let other: Bool = await withCheckedContinuation { continuation in
            receiver.helperDidFinishOutput(operation: UUID().uuidString) { success, _ in continuation.resume(returning: success) }
        }
        #expect(!other)
    }
'''+s[i:];s=s.replace('import Testing','import Testing\nimport VPhoneLaunchpadKit');p.write_text(s)
