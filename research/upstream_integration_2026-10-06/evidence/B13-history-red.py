from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/tests/VPhoneLaunchpadKitTests/OutputCompletionTests.swift')
s=p.read_text(); pos=s.rfind('\n}')
s=s[:pos]+'''
    @Test func logCreationFailureDoesNotLeaveRunningHistory() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let blocked = temp.url.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/usr/bin/true"), history: history, logsDirectory: blocked)
        do { _ = try await command.run([]); Issue.record("Expected log creation failure") }
        catch { #expect(history.entries.isEmpty) }
    }

    @Test func spawnFailureFinishesHistoryAndClosesLog() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: temp.url.appendingPathComponent("missing"), history: history, logsDirectory: temp.url)
        do { _ = try await command.run([]); Issue.record("Expected spawn failure") }
        catch {
            #expect(history.entries.count == 1)
            #expect(history.entries.first?.outcome == .failed)
            #expect(history.entries.first?.outputDrained == false)
        }
    }
''' + s[pos:];p.write_text(s)
