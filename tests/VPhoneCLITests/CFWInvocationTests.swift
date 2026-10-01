import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

/// The environment `vm create` and `cfw install` give the root CFW driver.
/// scripts/cfw_install_host.sh returns its artifacts to VPHONE_INVOKER_UID/GID
/// (tests/test_cfw_host_isolation.py covers the driver side).
struct CFWInvocationTests {
    static let scriptEnv = ["VPHONE_PYTHON": "/py", "IPSW_DIR": "/ipsw"]
    static let invoker = [VPhoneInvoker.uidKey: "501", VPhoneInvoker.gidKey: "20"]

    @Test func rootPopupPassesTheInvokerInlineWithoutSudoIdentity() throws {
        let invocation = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: Self.scriptEnv, sudoEnvExtras: [:], rootPopup: true,
            processEnvironment: ["HOME": "/Users/u", "SUDO_UID": "777"], invoker: Self.invoker, userName: "u")
        #expect(invocation.usePopup)
        // Only the inline variables: do shell script starts with a bare environment.
        #expect(invocation.env == Self.scriptEnv.merging(Self.invoker) { a, _ in a }.merging(["SUDO_USER": "u"]) { a, _ in a })
        let command = VPhoneProcessRunner.adminPrivilegesCommand(
            URL(fileURLWithPath: "/bin/zsh"), ["/s/cfw_install_host.sh", "--variant", "regular", "/vm"], env: invocation.env)
        #expect(command.contains("VPHONE_INVOKER_UID='501' "))
        #expect(command.contains("VPHONE_INVOKER_GID='20' "))
        #expect(!command.contains("SUDO_UID"))
        let script = VPhoneProcessRunner.adminPrivilegesScript(
            URL(fileURLWithPath: "/bin/zsh"), ["/vm with \"quote\""], env: invocation.env)
        #expect(script.hasPrefix("do shell script \"IPSW_DIR='/ipsw' SUDO_USER='u' VPHONE_INVOKER_GID='20' VPHONE_INVOKER_UID='501' "))
        #expect(script.hasSuffix("'/vm with \\\"quote\\\"'\" with administrator privileges"))
    }

    /// Stand-in for the authentication dialog: the same /bin/sh command line
    /// runs in an empty environment (`env -i`), as `do shell script` does, and
    /// the child sees the invoker ids and no SUDO_UID/SUDO_GID.
    @Test func inlineInvokerReachesABareShell() throws {
        let invocation = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: Self.scriptEnv, sudoEnvExtras: [:], rootPopup: true)
        let probe = #"printf '%s|%s|%s|%s' "$VPHONE_INVOKER_UID" "$VPHONE_INVOKER_GID" "${SUDO_UID-unset}" "${SUDO_GID-unset}""#
        let command = VPhoneProcessRunner.adminPrivilegesCommand(
            URL(fileURLWithPath: "/bin/sh"), ["-c", probe], env: invocation.env)
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/env"), ["-i", "/bin/sh", "-c", command], timeout: 10)
        #expect(result.succeeded)
        #expect(result.stdout == "\(getuid())|\(getgid())|unset|unset")
    }

    @Test func sudoPathAddsTheInvokerToTheInheritedEnvironment() {
        for extras in [[:], ["SUDO_ASKPASS": "/askpass", "SUDO_PASSWORD": "pw"]] as [[String: String]] {
            for popup in [false, true] where !(popup && extras.isEmpty) {
                let invocation = VPhoneCreateOrchestrator.cfwInvocation(
                    scriptEnv: Self.scriptEnv, sudoEnvExtras: extras, rootPopup: popup,
                    processEnvironment: ["HOME": "/Users/u", "PATH": "/usr/bin"], invoker: Self.invoker, userName: "u")
                // --sudo-password (askpass) wins over --root-popup.
                #expect(!invocation.usePopup)
                #expect(invocation.env["HOME"] == "/Users/u")
                #expect(invocation.env[VPhoneInvoker.uidKey] == "501")
                #expect(invocation.env[VPhoneInvoker.gidKey] == "20")
                #expect(invocation.env["VPHONE_PYTHON"] == "/py")
                #expect(invocation.env["SUDO_USER"] == nil)
                for (key, value) in extras { #expect(invocation.env[key] == value) }
            }
        }
        let plain = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: Self.scriptEnv, sudoEnvExtras: [:], rootPopup: false, processEnvironment: [:],
            invoker: Self.invoker, userName: "u")
        #expect(!plain.usePopup)
    }

    @Test func invokerIsTheRealUserOrSudoCaller() {
        #expect(VPhoneInvoker.environment(uid: 501, gid: 20, processEnvironment: ["SUDO_UID": "777"])
            == [VPhoneInvoker.uidKey: "501", VPhoneInvoker.gidKey: "20"])
        // Already root under sudo: sudo names the invoker.
        #expect(VPhoneInvoker.environment(uid: 0, gid: 0, processEnvironment: ["SUDO_UID": "501", "SUDO_GID": "20"])
            == [VPhoneInvoker.uidKey: "501", VPhoneInvoker.gidKey: "20"])
        #expect(VPhoneInvoker.environment(uid: 0, gid: 0, processEnvironment: ["SUDO_UID": "501"])
            == [VPhoneInvoker.uidKey: "501"])
        // Plain root, or sudo from root: 0, which the driver treats as "keep owners".
        for environment in [[:], ["SUDO_UID": "0", "SUDO_GID": "0"], ["SUDO_UID": "x"]] as [[String: String]] {
            #expect(VPhoneInvoker.environment(uid: 0, gid: 0, processEnvironment: environment)
                == [VPhoneInvoker.uidKey: "0", VPhoneInvoker.gidKey: "0"])
        }
        #expect(VPhoneInvoker.environment()[VPhoneInvoker.uidKey] == String(getuid()))
    }
}
