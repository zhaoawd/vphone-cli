import VPhoneCore
import Testing
@testable import VPhoneLaunchpadKit

struct MachineOriginsTests {
    @Test func recordedOriginsNeverBecomeRuntimeProof() throws {
        let binding = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1-local.ab12cd34", guestEnvironment: "2.5.9", kernel: "2.6.0", bootChain: "2.2.3")
        let presentation = VPhoneLaunchpadMachineOrigins(.loaded(binding))
        #expect(presentation.host == binding.bundle)
        #expect(presentation.guestEnvironment == binding.guestEnvironment)
        #expect(presentation.kernel == binding.kernel)
        #expect(presentation.bootChain == binding.bootChain)
        #expect(presentation.runtime == "Unknown")
        #expect(presentation.notice.contains("recorded"))
        #expect(presentation.notice.contains("receipts"))
    }

    @Test func missingAndInvalidBindingsRemainVisibleWithoutADefaultVersion() {
        let absent = VPhoneLaunchpadMachineOrigins(.missing)
        #expect(absent.host == "Unknown")
        #expect(absent.guestEnvironment == "Unknown")
        #expect(absent.kernel == "Unknown")
        #expect(absent.bootChain == "Unknown")
        #expect(absent.notice.contains("missing"))
        let invalid = VPhoneLaunchpadMachineOrigins(.invalid("invalid digest"))
        #expect(invalid.host == "Unknown")
        #expect(invalid.notice.contains("invalid digest"))
    }

    @Test func legacyKernelAndGuestStayUnknownEvenIfHostAndBootChainMatch() throws {
        let binding = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1", bootChain: "2.6.1")
        let presentation = VPhoneLaunchpadMachineOrigins(.loaded(binding))
        #expect(presentation.kernel == "Unknown")
        #expect(presentation.guestEnvironment == "Unknown")
        #expect(presentation.runtime == "Unknown")
    }
}
