import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct LineSplitterTests {
    private func reference(_ input: Data) -> [String] {
        input.split(omittingEmptySubsequences: false, whereSeparator: { $0 == 10 || $0 == 13 }).compactMap { bytes in
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        }
    }

    @Test func escapeScannerMatchesPreviousPatternIncludingIncompleteSequences() {
        let values = ["plain 中文", "\u{1b}[31mred\u{1b}[0m", "\u{1b}[?25l中文", "x\u{1b}[12;? /@y",
                      "\u{1b}[", "\u{1b}[31", "\u{1b}[3:1m", "\u{1b}x", "\u{1b}[\u{1b}[32m", "\u{1b}]title\u{07}"]
        for value in values {
            #expect(VPhoneLaunchpadLineSplitter.strippingEscapes(value)
                == value.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression))
        }
    }

    @Test func arbitraryChunkingPreservesCRLFUnicodeANSIAndTail() {
        let input = Data(("\t\u{a0}\u{200b}\u{3000}\n\r\n\u{1b}[31mpanic(cpu 0) 中文\u{1b}[0m\r"
            + String(repeating: "行\u{1b}[?25l progress\r\n", count: 1500)
            + "invalid\u{1b}[3:1m\n" + String(repeating: "long tail 🧪", count: 1000)).utf8) + Data([0xff, 0xfe])
        let expected = reference(input)
        for seed in 1...12 {
            var state = UInt64(seed), offset = 0
            var splitter = VPhoneLaunchpadLineSplitter(), lines: [String] = []
            while offset < input.count {
                state = state &* 6364136223846793005 &+ 1
                let end = min(input.count, offset + Int(state >> 32) % 4096 + 1)
                splitter.feed(input.subdata(in: offset..<end)) { lines.append($0) }
                offset = end
            }
            splitter.flush { lines.append($0) }
            #expect(lines == expected)
            splitter.flush { lines.append($0) }
            #expect(lines == expected)
        }
    }

    @Test func singleByteChunksPreserveIncompleteUTF8AndEscapeSequences() {
        let input = Data("\u{1b}[32m图像🧪\u{1b}[0m\r\n\t \nfinal\u{1b}[31".utf8)
        var splitter = VPhoneLaunchpadLineSplitter(), lines: [String] = []
        for byte in input { splitter.feed(Data([byte])) { lines.append($0) } }
        splitter.flush { lines.append($0) }
        #expect(lines == reference(input))
    }
}
