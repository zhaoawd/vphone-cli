import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct LaunchRouteTests {
    let embedded = URL(fileURLWithPath: "/tmp/embedded-cli")
    let launcher = URL(fileURLWithPath: "/tmp/launcher")
    @Test func missingBindingKeepsEmbeddedDevelopmentToolchain() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let args = ["vm", "launch", "machine"]
        let route = try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: args)
        #expect(route.executable == embedded)
        #expect(route.arguments == args)
    }
    @Test func boundMachineUsesLauncherAndExactVersion() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.1-local.12345678")).write(to: temp.url.appendingPathComponent("launchpad.json"))
        let route = try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: ["vm", "launch", "machine"])
        #expect(route.executable == launcher)
        #expect(route.arguments.first == "/Library/Application Support/vphone-launchpad/Bundles/2.6.1-local.12345678/VPhone.bundle/Contents/MacOS/vphone-cli")
        #expect(Array(route.arguments.dropFirst()) == ["vm", "launch", "machine", "--expected-binding-sha256", route.snapshot!.sha256])
        #expect(route.snapshot?.matches(temp.url) == true)
    }
    @Test func releaseBundleSelectsLocalWrapperWithFrozenBinding() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.1")).write(to: temp.url.appendingPathComponent("launchpad.json"))
        let arguments = ["vm", "launch", "machine", "--library-root", temp.url.path]
        let route = try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: arguments)
        #expect(Array(route.arguments.dropFirst()) == arguments + ["--expected-binding-sha256", route.snapshot!.sha256])
    }
    @Test func invalidBindingRefusesWithoutEmbeddedFallback() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try Data("{}".utf8).write(to: temp.url.appendingPathComponent("launchpad.json"))
        #expect(throws: (any Error).self) { try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: ["vm", "launch", "machine"]) }
    }
    @Test func boundMachineWithoutLauncherRefuses() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.1")).write(to: temp.url.appendingPathComponent("launchpad.json"))
        #expect(throws: (any Error).self) { try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: nil, machine: temp.url, arguments: ["vm", "launch", "machine"]) }
    }
}

extension LaunchRouteTests {
    @Test func kernelUpdateUsesFrozenBoundSource() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.1")).write(to: temp.url.appendingPathComponent("launchpad.json"))
        let arguments = ["vm", "update-kernel", "machine"]
        let route = try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: arguments)
        #expect(route.executable == launcher)
        #expect(Array(route.arguments.dropFirst()) == arguments + ["--expected-binding-sha256", route.snapshot!.sha256])
    }

    @Test @MainActor func kernelRecoveryDoesNotNeedReadablePublishedBinding() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let pending = temp.url.appendingPathComponent(".firmware-transaction")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        try Data("partial journal".utf8).write(to: pending.appendingPathComponent("journal.json"))
        try Data("partial binding".utf8).write(to: temp.url.appendingPathComponent("launchpad.json"))
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/usr/bin/true"), history: .init(), launcher: launcher)
        let result = try await command.updateKernel(name: "machine", libraryRoot: temp.url, machine: temp.url, recover: true)
        #expect(result.succeeded)
    }
}

extension LaunchRouteTests {
    @Test func rollbackUsesFrozenBoundProducer() throws {
        let temp = try LaunchpadTemporaryDirectory()
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.2")).write(to: temp.url.appendingPathComponent("launchpad.json"))
        let arguments = ["vm", "rollback-kernel", "machine", "--to-transaction", UUID().uuidString.lowercased()]
        let route = try VPhoneLaunchpadLaunchRoute.resolve(embedded: embedded, launcher: launcher, machine: temp.url, arguments: arguments)
        #expect(route.executable == launcher)
        #expect(Array(route.arguments.dropFirst()) == arguments + ["--expected-binding-sha256", route.snapshot!.sha256])
    }
}
