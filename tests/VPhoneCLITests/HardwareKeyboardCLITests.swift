import Foundation
import Testing
@testable import vphone_cli

struct HardwareKeyboardCLITests {
    @Test func configurationParsesExplicitChoiceAndRejectsUnknownValues() throws {
        for (value, enabled) in [("on", true), ("off", false)] {
            let parsed = try #require(VPhoneCLI.parseAsRoot(["vm", "config", "vm", "--hardware-keyboard", value]) as? VPhoneVMConfigCommand)
            #expect(parsed.hardwareKeyboard?.enabled == enabled)
        }
        #expect(throws: (any Error).self) { try VPhoneCLI.parseAsRoot(["vm", "config", "vm", "--hardware-keyboard", "maybe"]) }
        let original = try #require(VPhoneCLI.parseAsRoot(["vm", "config", "vm", "--cpu", "4"]) as? VPhoneVMConfigCommand)
        #expect(original.hardwareKeyboard == nil)
    }
}
