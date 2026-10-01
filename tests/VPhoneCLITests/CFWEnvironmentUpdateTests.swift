import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

/// `cfw update-environment` acts only on offline_update. The classification
/// itself is tested in tests/test_cfw_env_update.py.
struct CFWEnvironmentUpdateTests {
    static func report(_ classification: String, replace: [String] = [], reasons: [String] = [],
                       migration: String? = nil) -> String {
        var object: [String: Any] = ["classification": classification, "replace": replace, "reasons": reasons]
        if let migration { object["migration"] = migration }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func offlineUpdateIsTheOnlyClassificationThatReplaces() {
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("offline_update", replace: ["libcamfix.dylib"]), stderr: "")
            == .replace(libraries: ["libcamfix.dylib"]))
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("already_current"), stderr: "") == .nothingToDo)
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0,
            stdout: Self.report("full_migration_required", reasons: ["/usr/lib/libcamfix.dylib is missing"],
                                migration: "create a new VM"),
            stderr: "")
            == .refuse(classification: "full_migration_required",
                       reasons: ["/usr/lib/libcamfix.dylib is missing", "create a new VM"], exitCode: 3))
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("not_applicable", reasons: ["recorded variant less installs no CFW"]),
            stderr: "")
            == .refuse(classification: "not_applicable", reasons: ["recorded variant less installs no CFW"], exitCode: 3))
    }

    @Test func checkFailuresRefuseExceptUnreadableDisk() {
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 4, stdout: "", stderr: "[-] VM lock held\n")
            == .refuse(classification: nil, reasons: ["[-] VM lock held"], exitCode: 4))
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 2, stdout: "", stderr: "")
            == .refuse(classification: nil, reasons: [], exitCode: 2))
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 0, stdout: "not json", stderr: "")
            == .refuse(classification: nil, reasons: ["the eligibility check returned no classification"], exitCode: 2))
        // The root driver repeats the classification on the staged copy.
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 5, stdout: "", stderr: "[-] disk access failed: x\n")
            == .replaceAfterRootCheck(detail: "[-] disk access failed: x"))
    }

    @Test func driverRunsInEnvironmentModeWithoutAVariant() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/res"))
        let args = VPhoneCFWUpdateEnvironmentCommand.driverArguments(
            resources: resources, bundle: URL(fileURLWithPath: "/vms/a"))
        #expect(args == ["/res/scripts/cfw_install_host.sh", "--update-environment", "/vms/a"])
        #expect(resources.cfwEnvUpdateScript.path == "/res/scripts/cfw_env_update.py")
        #expect(resources.guestComponentsStage.path == "/res/.build/guest-components-v2/stage")
    }

    @Test func commandIsRegisteredUnderCFW() throws {
        let parsed = try VPhoneCFWCommand.parseAsRoot(["update-environment", "vm-a", "--check"])
        let command = try #require(parsed as? VPhoneCFWUpdateEnvironmentCommand)
        #expect(command.check)
        #expect(command.name == "vm-a")
    }
}
