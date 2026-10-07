import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct HardwareKeyboardSettingsTests {
    @Test func keyboardEditPassesOnlyTheExplicitSelection() {
        let path = VPhoneLaunchpadMachinePath(libraryRoot: "/lib", name: "m1")
        #expect(VPhoneLaunchpadEditCommand.config(path, .init(hardwareKeyboardEnabled: false))?.arguments == ["vm", "config", "m1", "--library-root", "/lib", "--hardware-keyboard", "off"])
        #expect(VPhoneLaunchpadEditCommand.config(path, .init(hardwareKeyboardEnabled: true))?.arguments == ["vm", "config", "m1", "--library-root", "/lib", "--hardware-keyboard", "on"])
        #expect(VPhoneLaunchpadEditCommand.config(path, .init(cpu: 4))?.arguments == ["vm", "config", "m1", "--library-root", "/lib", "--cpu", "4"])
    }
    @Test func reportPreservesOptionalKeyboardFlagAndLegacyDefault() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "keyboard", in: temp.url)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VPhoneBundleReport(bundle: bundle))) as? [String: Any])
        let legacy = try VPhoneLaunchpadMachine.decodeList(JSONSerialization.data(withJSONObject: [object]), libraryRoot: temp.canonicalPath)[0]
        #expect(legacy.usesHardwareKeyboard)
        let configured = VPhoneBundle(url: bundle.url, manifest: bundle.manifest.updating(hardwareKeyboardEnabled: false))
        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VPhoneBundleReport(bundle: configured))) as? [String: Any])
        let disabled = try VPhoneLaunchpadMachine.decodeList(JSONSerialization.data(withJSONObject: [object]), libraryRoot: temp.canonicalPath)[0]
        #expect(!disabled.usesHardwareKeyboard)
    }
}
