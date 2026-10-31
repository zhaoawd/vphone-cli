import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct EnvironmentBindingTests {
    @Test func boundComponentInputsStayInsideTheSelectedProducer() throws {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/selected/Contents/Resources"))
        #expect(try VPhoneCFWUpdateEnvironmentCommand.componentStage(resources: resources,
            components: nil, projectRoot: nil, bound: true).path
            == "/selected/Contents/Resources/.build/guest-components-v2/stage")
        #expect(throws: (any Error).self) {
            try VPhoneCFWUpdateEnvironmentCommand.componentStage(resources: resources,
                components: "/untrusted/components", projectRoot: nil, bound: true)
        }
        #expect(throws: (any Error).self) {
            try VPhoneCFWUpdateEnvironmentCommand.componentStage(resources: resources,
                components: nil, projectRoot: "/untrusted/resources", bound: true)
        }
        #expect(try VPhoneCFWUpdateEnvironmentCommand.componentStage(resources: resources,
            components: "/development/components", projectRoot: nil, bound: false).path == "/development/components")
    }

    @Test func expectedBindingMustMatchBeforeAnEnvironmentUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("launchpad.json")
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.2", guestEnvironment: "2.6.1")).write(to: file)
        let snapshot = try #require(try VPhoneMachineBinding.snapshot(root))
        let command = try VPhoneCFWUpdateEnvironmentCommand.parse(["phone", "--expected-binding-sha256", snapshot.sha256, "--expected-core-bundle", "2.6.2"])
        #expect(command.expectedBindingSha256 == snapshot.sha256 && command.expectedCoreBundle == "2.6.2")
        #expect(try VPhoneCFWUpdateEnvironmentCommand.bindingEnvironment(machine: root,
            expectedSHA256: snapshot.sha256, expectedBundle: "2.6.2")
            == ["VPHONE_EXPECTED_BINDING_SHA256": snapshot.sha256, "VPHONE_EXPECTED_CORE_BUNDLE": "2.6.2"])
        try VPhoneVMBindCoreBundleCommand.validateExpectedBinding(snapshot.sha256, snapshot: snapshot)
        #expect(throws: (any Error).self) { try VPhoneVMBindCoreBundleCommand.validateExpectedBinding("missing", snapshot: snapshot) }
        try VPhoneVMBindCoreBundleCommand.validateExpectedBinding("missing", snapshot: nil)
        #expect(try VPhoneCFWUpdateEnvironmentCommand.bindingEnvironment(machine: root, expectedSHA256: nil, expectedBundle: nil).isEmpty)
        #expect(throws: (any Error).self) { try VPhoneCFWUpdateEnvironmentCommand.bindingEnvironment(machine: root, expectedSHA256: nil, expectedBundle: "2.6.2") }
        #expect(throws: (any Error).self) { try VPhoneCFWUpdateEnvironmentCommand.bindingEnvironment(machine: root, expectedSHA256: snapshot.sha256, expectedBundle: nil) }
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.3")).write(to: file)
        #expect(throws: (any Error).self) { try VPhoneCFWUpdateEnvironmentCommand.bindingEnvironment(machine: root, expectedSHA256: snapshot.sha256, expectedBundle: "2.6.2") }
    }
}
