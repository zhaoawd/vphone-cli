from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneCLITests/GuestShutdownTests.swift').write_text('''import Foundation
import Testing
@testable import vphone_cli

@MainActor
struct GuestShutdownTests {
    @Test func apiAcceptanceWaitsForVMStopWithoutAlsoSendingClassicHalt() async {
        var classic = 0
        let request = VPhoneGuestShutdown(api: { true }, classic: { classic += 1; return true }, running: { true })
        #expect(await request.request() == .apiAccepted)
        #expect(classic == 0)
    }
    @Test func apiFailureFallsBackToClassicOnlyWhileVMIsRunning() async {
        for running in [false, true] {
            var classic = 0
            let request = VPhoneGuestShutdown(api: { throw CancellationError() }, classic: { classic += 1; return true }, running: { running })
            #expect(await request.request() == (running ? .classicAccepted : .alreadyStopped))
            #expect(classic == (running ? 1 : 0))
        }
    }
    @Test func missingOrRefusedGuestMethodsRequestFrameworkFallback() async {
        let request = VPhoneGuestShutdown(api: nil, classic: { false }, running: { true })
        #expect(await request.request() == .frameworkRequired)
    }
}
''')
(r/'sources/vphone-cli/VPhoneGuestShutdown.swift').write_text('''import Foundation
@MainActor
struct VPhoneGuestShutdown {
    enum Result: Equatable { case apiAccepted, classicAccepted, alreadyStopped, frameworkRequired }
    let api: (() async throws -> Bool)?
    let classic: () async -> Bool
    let running: () -> Bool
    func request() async -> Result { .frameworkRequired }
}
''')
