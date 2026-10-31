import Foundation
import Testing
import VPhoneAPIKit
@testable import vphone_cli

@MainActor
struct GuestShutdownTests {
    @Test func defaultGUIStopCanTryGuestAPIWithoutEnablingHTTPProxy() throws {
        let cli = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"])
        let app = VPhoneAppDelegate(cli: cli)
        #expect(cli.apiListen == nil)
        let connector: VPhoneAPIProxy.Connector = { _ in }
        #expect(app.guestAPIShutdownRequest(connector: connector) != nil)
    }

    @Test func disabledGuestChannelsDoNotAttemptDirectAPIShutdown() throws {
        for flag in ["--dfu", "--no-vphoned"] {
            let app = VPhoneAppDelegate(cli: try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", flag]))
            let connector: VPhoneAPIProxy.Connector = { _ in }
            #expect(app.guestAPIShutdownRequest(connector: connector) == nil)
        }
        let app = VPhoneAppDelegate(cli: try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"]))
        #expect(app.guestAPIShutdownRequest(connector: nil) == nil)
    }

    @Test func defaultStopRequestFallsBackWhenGuestAPIIsUnavailable() async throws {
        let app = VPhoneAppDelegate(cli: try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"]))
        let connector: VPhoneAPIProxy.Connector = { reply in reply(.failure(CancellationError())) }
        let api = try #require(app.guestAPIShutdownRequest(connector: connector))
        var classic = 0
        let request = VPhoneGuestShutdown(api: api, classic: { classic += 1; return false }, running: { true })
        #expect(await request.request() == .frameworkRequired)
        #expect(classic == 1)
    }

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
