import Foundation
import Testing
@testable import VPhoneCore

struct ClipboardTransferTests {
    @Test func textLimitsCountUTF8Bytes() {
        let limit = VPhoneClipboardTransfer.maxTextBytes
        #expect(VPhoneClipboardTransfer.fits(text: ""))
        #expect(VPhoneClipboardTransfer.fits(text: String(repeating: "x", count: limit)))
        #expect(!VPhoneClipboardTransfer.fits(text: String(repeating: "x", count: limit + 1)))
        #expect(VPhoneClipboardTransfer.fits(text: String(repeating: "中", count: limit / 3)))
        #expect(!VPhoneClipboardTransfer.fits(text: String(repeating: "中", count: limit / 3 + 1)))
    }

    @Test func imageLimitsApplyToEncodedNonemptyBytes() {
        let limit = VPhoneClipboardTransfer.maxImageBytes
        #expect(!VPhoneClipboardTransfer.fits(image: Data()))
        #expect(VPhoneClipboardTransfer.fits(image: Data([0])))
        #expect(VPhoneClipboardTransfer.fits(image: Data(repeating: 0, count: limit)))
        #expect(!VPhoneClipboardTransfer.fits(image: Data(repeating: 0, count: limit + 1)))
    }

    @Test func macRepresentationPreservesOwnerPreferenceAndExcludesRichTextOnly() {
        #expect(VPhoneClipboardTransfer.macKind(types: ["public.rtf", "public.file-url"]) == nil)
        #expect(VPhoneClipboardTransfer.macKind(types: ["public.png", "public.utf8-plain-text"]) == .image(type: "public.png"))
        #expect(VPhoneClipboardTransfer.macKind(types: ["public.utf8-plain-text", "public.png"]) == .text)
        #expect(VPhoneClipboardTransfer.macKind(types: ["public.tiff"]) == .image(type: "public.tiff"))
        #expect(!VPhoneClipboardTransfer.guestImageTypes.contains("public.tiff"))
    }

    @Test func guestTextWinsOnlyWhenNonempty() {
        #expect(VPhoneClipboardTransfer.guestKind(text: "a", hasImage: true) == .text)
        #expect(VPhoneClipboardTransfer.guestKind(text: "", hasImage: true) == .image(type: "public.png"))
        #expect(VPhoneClipboardTransfer.guestKind(text: nil, hasImage: false) == nil)
    }
}
