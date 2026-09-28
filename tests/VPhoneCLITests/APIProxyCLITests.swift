import ArgumentParser
import Testing
@testable import vphone_cli

struct APIProxyCLITests {
    @Test func explicitProxyOptionIsForwardedWithoutToken() throws {
        let boot = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--headless", "--api-listen", "127.0.0.1:0"])
        #expect(boot.apiListen == "127.0.0.1:0")
        let launch = try VPhoneVMLaunchCommand.parse(["sample", "--api-listen", "127.0.0.1:8765"])
        #expect(launch.apiProxyArguments() == ["--api-listen", "127.0.0.1:8765"])
        #expect(try VPhoneVMLaunchCommand.parse(["sample"]).apiProxyArguments().isEmpty)
    }

    @Test func rejectsUnsupportedModesAndAddresses() {
        for flag in ["--dfu", "--no-vphoned"] {
            #expect(throws: (any Error).self) { try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", flag, "--api-listen", "127.0.0.1:0"]) }
            #expect(throws: (any Error).self) { try VPhoneVMLaunchCommand.parse(["sample", flag, "--api-listen", "127.0.0.1:0"]) }
        }
        for address in ["0.0.0.0:8765", "localhost:1", "127.0.0.1:-1", "127.0.0.1:65536", "127.0.0.1:1/path"] {
            #expect(throws: (any Error).self) { try VPhoneAPIProxyOptions.port(address) }
        }
    }

    @Test func tokenValidationHappensBeforeStartingVMAndDoesNotEchoSecret() throws {
        #expect(try VPhoneAPIProxyOptions.resolve(listen: nil, environment: [:]) == nil)
        #expect(throws: (any Error).self) { try VPhoneAPIProxyOptions.resolve(listen: "127.0.0.1:0", environment: [:]) }
        let value = try #require(try VPhoneAPIProxyOptions.resolve(listen: "127.0.0.1:0", environment: ["VPHONE_API_TOKEN": "1234567890abcdef"]))
        #expect(value.port == 0)
        #expect(value.token == "1234567890abcdef")
        do {
            _ = try VPhoneAPIProxyOptions.resolve(listen: "127.0.0.1:0", environment: ["VPHONE_API_TOKEN": "SECRET!INVALID"])
            Issue.record("Expected invalid token")
        } catch { #expect(!String(describing: error).contains("SECRET!INVALID")) }
    }
}
