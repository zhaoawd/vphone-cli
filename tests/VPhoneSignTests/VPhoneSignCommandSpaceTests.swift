import Foundation
import MachO
import Testing
@testable import VPhoneSign

/// Load command space, and load commands that do not describe the file.
///
/// Upstream ee8b70ca: CFW's launchd injection removes LC_CODE_SIGNATURE and
/// spends that slot plus the header padding on LC_LOAD_WEAK_DYLIB, so the
/// re-sign has no room left for the fresh LC_CODE_SIGNATURE. The signer then
/// drops LC_SOURCE_VERSION, and otherwise fails with noRoom.
///
/// Upstream cd45b8fa, which also drops LC_UUID, is not adopted: host dyld
/// refuses a main executable without LC_UUID, and the guest's behaviour is
/// not verified. LC_UUID is never removed here.
///
/// The inputs are built from `hello-arm64` by a parser in this file, not the
/// signer's own, so the fixture does not depend on the code under test.
@Suite("Load command space and damaged load commands")
struct VPhoneSignCommandSpaceTests {
    // MARK: - Building inputs

    private static let headerSize = 32

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    private static func store32(_ value: UInt32, in data: inout Data, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
    }

    /// Every load command of a thin 64-bit Mach-O, in file order.
    private static func commands(_ data: Data) -> [(command: UInt32, offset: Int, bytes: Data)] {
        var found: [(UInt32, Int, Data)] = []
        var cursor = headerSize
        for _ in 0 ..< Int(le32(data, 16)) {
            let size = Int(le32(data, cursor + 4))
            found.append((le32(data, cursor), cursor, data.subdata(in: cursor ..< cursor + size)))
            cursor += size
        }
        return found
    }

    /// The lowest non-zero section file offset: where the command area has
    /// to end.
    private static func firstContent(_ data: Data) -> Int {
        var lowest = Int.max
        for (command, offset, _) in commands(data) where command == UInt32(LC_SEGMENT_64) {
            for index in 0 ..< Int(le32(data, offset + 64)) {
                let section = Int(le32(data, offset + 72 + index * 80 + 48))
                if section > 0 { lowest = min(lowest, section) }
            }
        }
        return lowest
    }

    /// `hello-arm64` as CFW's launchd injection leaves a binary: no
    /// LC_CODE_SIGNATURE, the `dropping` commands gone, and an
    /// LC_LOAD_WEAK_DYLIB for `/vh` grown to leave exactly `slack` bytes
    /// before the first section.
    private static func injected(dropping: Set<UInt32> = [], slack: Int = 0) throws -> Data {
        var data = try Data(contentsOf: VPhoneSignFixtures.url("hello-arm64"))
        let kept = commands(data).filter {
            $0.command != UInt32(LC_CODE_SIGNATURE) && !dropping.contains($0.command)
        }
        let limit = firstContent(data) - headerSize
        let keptSize = kept.reduce(0) { $0 + $1.bytes.count }
        let fillerSize = limit - keptSize - slack
        try #require(fillerSize >= 32 && fillerSize % 8 == 0, "filler of \(fillerSize) bytes")

        // dylib_command: cmd, cmdsize, name.offset, timestamp,
        // current_version, compatibility_version, then the name.
        var filler = Data(count: fillerSize)
        for (index, word) in [UInt32(LC_LOAD_WEAK_DYLIB), UInt32(fillerSize), 24, 2, 0x10000, 0x10000].enumerated() {
            store32(word, in: &filler, at: index * 4)
        }
        filler.replaceSubrange(24 ..< 27, with: Array("/vh".utf8))

        var area = kept.reduce(Data()) { $0 + $1.bytes }
        area.append(filler)
        data.replaceSubrange(headerSize ..< headerSize + limit, with: area + Data(count: limit - area.count))
        store32(UInt32(kept.count + 1), in: &data, at: 16)
        store32(UInt32(area.count), in: &data, at: 20)
        return data
    }

    private static func commandSet(_ data: Data) -> [UInt32] {
        commands(data).map(\.command)
    }

    private func write(_ data: Data, as name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func isNoRoom(_ error: VPhoneSignError?) -> Bool {
        if case .noRoom = error { return true }
        return false
    }

    private func isMalformed(_ error: VPhoneSignError?) -> Bool {
        if case .malformed = error { return true }
        return false
    }

    // MARK: - Space

    @Test
    func `the constructed inputs have exactly the room they claim`() throws {
        let full = try Self.injected()
        let area = Self.headerSize + Int(Self.le32(full, 20))
        #expect(area == Self.firstContent(full))
        #expect(!Self.commandSet(full).contains(UInt32(LC_CODE_SIGNATURE)))
        #expect(Self.commandSet(full).contains(UInt32(LC_LOAD_WEAK_DYLIB)))
        #expect(Self.commandSet(full).contains(UInt32(LC_SOURCE_VERSION)))
    }

    /// Room for the new command: nothing is dropped.
    @Test
    func `with room left, LC_SOURCE_VERSION and LC_UUID are kept`() throws {
        let signed = try VPhoneSigner.sign(try Self.injected(slack: 16), options: .init(identifier: "launchd"))
        let commands = Self.commandSet(signed)
        #expect(commands.contains(UInt32(LC_SOURCE_VERSION)))
        #expect(commands.contains(UInt32(LC_UUID)))
        #expect(commands.last == UInt32(LC_CODE_SIGNATURE))
    }

    /// The iOS 18.6.2 launchd shape (ee8b70ca).
    @Test
    func `with no room, LC_SOURCE_VERSION is dropped and LC_UUID is kept`() throws {
        let input = try Self.injected()
        let signed = try VPhoneSigner.sign(input, options: .init(identifier: "launchd"))
        let commands = Self.commandSet(signed)
        #expect(!commands.contains(UInt32(LC_SOURCE_VERSION)))
        #expect(commands.contains(UInt32(LC_UUID)))
        #expect(commands.contains(UInt32(LC_LOAD_WEAK_DYLIB)))
        #expect(commands.last == UInt32(LC_CODE_SIGNATURE))
        // Every other command survives, in order.
        let expected = Self.commandSet(input).filter { $0 != UInt32(LC_SOURCE_VERSION) } + [UInt32(LC_CODE_SIGNATURE)]
        #expect(commands == expected)
        // The command area still ends where the first section starts.
        #expect(Self.headerSize + Int(Self.le32(signed, 20)) <= Self.firstContent(signed))
        #expect(Self.le32(signed, 16) == UInt32(commands.count))
        // The code after the command area is unchanged.
        let start = Self.firstContent(input)
        let textEnd = start + 0x64
        #expect(signed.subdata(in: start ..< textEnd) == input.subdata(in: start ..< textEnd))
    }

    /// The iOS 26.3 launchd shape (cd45b8fa): no LC_SOURCE_VERSION to drop.
    /// Upstream drops LC_UUID here; this signer keeps it and refuses.
    @Test
    func `with no room and no LC_SOURCE_VERSION, LC_UUID is kept and signing fails`() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.injected(dropping: [UInt32(LC_SOURCE_VERSION)])
        #expect(Self.commandSet(input).contains(UInt32(LC_UUID)))
        let file = try write(input, as: "launchd", in: directory)

        let error = #expect(throws: VPhoneSignError.self) { try VPhoneSigner.sign(fileAt: file) }
        #expect(isNoRoom(error), "\(String(describing: error))")
        #expect(try Data(contentsOf: file) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["launchd"])
    }

    @Test
    func `with no room and nothing to drop, signing fails and the file is unchanged`() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.injected(dropping: [UInt32(LC_SOURCE_VERSION), UInt32(LC_UUID)])
        let file = try write(input, as: "launchd", in: directory)

        let error = #expect(throws: VPhoneSignError.self) { try VPhoneSigner.sign(fileAt: file) }
        #expect(isNoRoom(error), "\(String(describing: error))")
        #expect(try Data(contentsOf: file) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["launchd"])
    }

    /// Entitlements host codesign reads as valid. The parity suite's sample
    /// carries integers codesign reports as "an invalid entitlements blob",
    /// which fails its designated-requirement check on any file, dropped
    /// command or not.
    private static let hostEntitlements = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>platform-application</key>
    \t<true/>
    \t<key>get-task-allow</key>
    \t<true/>
    \t<key>com.apple.security.exception.files.absolute-path.read-only</key>
    \t<array>
    \t\t<string>/usr/lib/</string>
    \t</array>
    </dict>
    </plist>

    """.utf8)

    /// What was written after LC_SOURCE_VERSION is dropped is a signature the
    /// host accepts, carrying the entitlements it was given, and it signs
    /// again unchanged.
    @Test
    func `after a drop the signature verifies and carries the entitlements`() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.injected()
        let plist = Self.hostEntitlements

        // ldid style, with entitlements: read back and compared after a parse.
        let ldid = try write(input, as: "launchd", in: directory)
        try VPhoneSigner.sign(fileAt: ldid, options: .init(identifier: "launchd", entitlements: plist))
        let read = try VPhoneSigner.entitlements(ofFileAt: ldid)
        #expect(read.count == 1)
        let ours = try PropertyListSerialization.propertyList(from: #require(read.first), format: nil) as? [String: Any]
        let original = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        #expect(NSDictionary(dictionary: ours ?? [:]) == NSDictionary(dictionary: original ?? [:]))
        let blobs = try #require(VPhoneSignBlobs(fileAt: ldid).slices.first)
        #expect(blobs[0] != nil, "no CodeDirectory")
        #expect(blobs[5] != nil, "no entitlements blob")

        // Signing the output again changes nothing: the fresh command now
        // occupies the slot the old one freed.
        let once = try Data(contentsOf: ldid)
        try VPhoneSigner.sign(fileAt: ldid, options: .init(identifier: "launchd", entitlements: plist))
        #expect(try Data(contentsOf: ldid) == once)

        // Apple ad-hoc style: codesign checks the hashes against the bytes.
        let apple = try write(input, as: "launchd-apple", in: directory)
        try VPhoneSigner.sign(fileAt: apple, options: .init(identifier: "launchd", entitlements: plist, style: .appleAdHoc))
        let result = try VPhoneSignFixtures.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", "-vvv", apple.path])
        #expect(result.status == 0, "\(result.error)")
        let dumped = try VPhoneSignFixtures.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["-d", "--entitlements", "-", "--xml", apple.path])
        #expect(dumped.status == 0, "\(dumped.error)")
        let fromCodesign = try PropertyListSerialization.propertyList(from: dumped.out, format: nil) as? [String: Any]
        #expect(NSDictionary(dictionary: fromCodesign ?? [:]) == NSDictionary(dictionary: original ?? [:]))

        // Host execution, without entitlements: the host kills an ad-hoc
        // binary claiming platform-application.
        let runnable = try write(input, as: "launchd-run", in: directory)
        try VPhoneSigner.sign(fileAt: runnable, options: .init(identifier: "launchd", style: .appleAdHoc))
        #expect(Self.commandSet(try Data(contentsOf: runnable)).contains(UInt32(LC_UUID)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnable.path)
        let run = try VPhoneSignFixtures.run(runnable, [])
        #expect(run.status == 0, "\(run.error)")
        #expect(!run.out.isEmpty)
    }

    // MARK: - Damaged load commands

    /// One way each to make a load command disagree with the file.
    enum Damage: String, CaseIterable, Sendable {
        case zeroSize
        case sizeNotMultipleOfEight
        case sizePastCommandArea
        case moreCommandsThanFit
        case commandAreaPastFile
        case signaturePastFile
        case shortSignatureCommand
        case segmentWithTooManySections
        case stringTablePastSignature
    }

    private static func damaged(_ damage: Damage) throws -> Data {
        var data = try Data(contentsOf: VPhoneSignFixtures.url("hello-arm64"))
        let all = commands(data)
        let first = try #require(all.first)
        let signature = try #require(all.first { $0.command == UInt32(LC_CODE_SIGNATURE) })
        let symtab = try #require(all.first { $0.command == UInt32(LC_SYMTAB) })
        switch damage {
        case .zeroSize:
            store32(0, in: &data, at: first.offset + 4)
        case .sizeNotMultipleOfEight:
            store32(UInt32(first.bytes.count + 4), in: &data, at: first.offset + 4)
        case .sizePastCommandArea:
            let last = try #require(all.last)
            store32(UInt32(last.bytes.count + 8), in: &data, at: last.offset + 4)
        case .moreCommandsThanFit:
            store32(UInt32(all.count + 1), in: &data, at: 16)
        case .commandAreaPastFile:
            store32(UInt32(data.count), in: &data, at: 20)
        case .signaturePastFile:
            store32(UInt32(data.count), in: &data, at: signature.offset + 12)
        case .shortSignatureCommand:
            // LC_CODE_SIGNATURE cut to 8 bytes, smaller than
            // linkedit_data_command, and an unknown 8-byte command after it,
            // so the command area size and the command count still agree.
            store32(8, in: &data, at: signature.offset + 4)
            store32(0xFF, in: &data, at: signature.offset + 8)
            store32(8, in: &data, at: signature.offset + 12)
            store32(UInt32(all.count + 1), in: &data, at: 16)
        case .segmentWithTooManySections:
            store32(1000, in: &data, at: first.offset + 64)
        case .stringTablePastSignature:
            store32(UInt32(data.count), in: &data, at: symtab.offset + 20)
        }
        return data
    }

    @Test(arguments: Damage.allCases)
    func `a damaged load command is refused and the file is unchanged`(damage: Damage) throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try Self.damaged(damage)
        let file = try write(input, as: "binary", in: directory)

        let error = #expect(throws: VPhoneSignError.self) { try VPhoneSigner.sign(fileAt: file) }
        #expect(isMalformed(error), "\(String(describing: error))")
        // The string table end is checked when the code limit is worked out,
        // which reading entitlements does not need.
        if damage != .stringTablePastSignature {
            let readError = #expect(throws: VPhoneSignError.self) { try VPhoneSigner.entitlements(ofFileAt: file) }
            #expect(isMalformed(readError), "\(String(describing: readError))")
        }
        #expect(try Data(contentsOf: file) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["binary"])
    }
}
