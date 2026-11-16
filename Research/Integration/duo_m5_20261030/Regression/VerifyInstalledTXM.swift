import CryptoKit
import Foundation
import Img4tool

// Read-only artifact probe. DER offsets are decoded from the containers;
// firmware payloads are unpacked by the same Img4tool used in production.
@main struct VerifyInstalledTXM {
    struct Element {
        let tag: UInt8
        let whole: Range<Int>
        let body: Range<Int>
    }
    enum Failure: Error { case invalidDER, invalidContainer, wrongPayload }

    static func element(_ data: Data, at start: Int) throws -> Element {
        guard start >= 0, start < data.count - 1 else { throw Failure.invalidDER }
        var cursor = start + 2
        let marker = data[start + 1]
        let length: Int
        if marker < 128 { length = Int(marker) }
        else {
            let count = Int(marker & 127)
            guard (1...4).contains(count), cursor <= data.count - count else { throw Failure.invalidDER }
            length = data[cursor..<(cursor + count)].reduce(0) { ($0 << 8) | Int($1) }
            cursor += count
        }
        guard length <= data.count - cursor else { throw Failure.invalidDER }
        return Element(tag: data[start], whole: start..<(cursor + length), body: cursor..<(cursor + length))
    }

    static func unwrap(_ data: Data) throws -> Data {
        let root = try element(data, at: 0)
        guard root.tag == 0x30, root.whole.upperBound == data.count else { throw Failure.invalidContainer }
        let name = try element(data, at: root.body.lowerBound)
        guard name.tag == 0x16 else { throw Failure.invalidContainer }
        switch String(decoding: data[name.body], as: UTF8.self) {
        case "IM4P": return data
        case "IMG4":
            let payload = try element(data, at: name.whole.upperBound)
            guard payload.tag == 0x30, payload.whole.upperBound <= root.body.upperBound else { throw Failure.invalidContainer }
            let payloadName = try element(data, at: payload.body.lowerBound)
            guard payloadName.tag == 0x16, String(decoding: data[payloadName.body], as: UTF8.self) == "IM4P" else { throw Failure.invalidContainer }
            return data.subdata(in: payload.whole)
        default: throw Failure.invalidContainer
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidContainer }
        let expected = try unwrap(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let installed = try unwrap(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let expectedImage = try IM4P(expected), installedImage = try IM4P(installed)
        guard expectedImage.fourcc == "trxm", installedImage.fourcc == "trxm" else { throw Failure.wrongPayload }
        let expectedPayload = try expectedImage.payload(), installedPayload = try installedImage.payload()
        let report: [String: Any] = [
            "expectedIM4PSHA256": hash(expected), "installedIM4PSHA256": hash(installed),
            "expectedPayloadSHA256": hash(expectedPayload), "installedPayloadSHA256": hash(installedPayload),
            "im4pExactMatch": expected == installed, "payloadExactMatch": expectedPayload == installedPayload,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
        guard expectedPayload == installedPayload else { throw Failure.wrongPayload }
    }
}
