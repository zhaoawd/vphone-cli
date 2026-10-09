import Testing
@testable import VPhoneCore

struct DeviceIdentityCheckTests {
    @Test func usbSerialAndGuestUDIDAgreeWithoutInferringTrust() {
        let check = VPhoneDeviceIdentityCheck(expected: "0000FE01-0011223344556677", guest: "0000fe01-0011223344556677", host: "0000FE010011223344556677")
        #expect(check.state == .matching)
        #expect(check.host == "0000FE01-0011223344556677")
    }
    @Test func missingObservationDoesNotUsePredictionAsReadback() {
        let check = VPhoneDeviceIdentityCheck(expected: "0000FE01-0011223344556677", guest: nil, host: nil)
        #expect(check.state == .incomplete)
        #expect(check.guest == nil && check.host == nil)
    }
    @Test func disagreementAndMalformedEvidenceStayDistinct() {
        #expect(VPhoneDeviceIdentityCheck(expected: "0000FE01-0011223344556677", guest: "0000FE01-0011223344556678", host: nil).state == .mismatch)
        #expect(VPhoneDeviceIdentityCheck(expected: "0000FE01-0011223344556677", guest: "arbitrary", host: nil).state == .invalid)
        #expect(VPhoneDeviceIdentityCheck(expected: String(repeating: "a", count: 40), guest: String(repeating: "A", count: 40), host: String(repeating: "A", count: 40)).state == .matching)
    }
}
