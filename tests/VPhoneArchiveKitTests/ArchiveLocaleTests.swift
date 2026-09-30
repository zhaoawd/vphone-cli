import ArchiveKit
import Darwin
import Foundation
import Testing
@testable import VPhoneArchiveKit

/// Non-ASCII member names and link targets when the calling thread runs in the
/// "C" locale.
///
/// libarchive converts names through the calling thread's LC_CTYPE. vphone-cli
/// never calls setlocale(3), so a terminal launch, a Launchpad child and the
/// root helper all run in "C", whose codeset is US-ASCII. Each test pins its
/// own thread to "C" with uselocale(3), so the result does not depend on how
/// the test runner set up its locale.
@Suite("Archive names in the C locale", .serialized)
struct ArchiveLocaleTests {
    // MARK: - Helpers

    private func inLocale<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let locale = try #require(newlocale(LC_CTYPE_MASK, name, nil))
        let previous = uselocale(locale)
        defer {
            uselocale(previous)
            freelocale(locale)
        }
        return try body()
    }

    /// The LC_CTYPE codeset of the calling thread's current locale.
    private static func threadCodeset() -> String {
        String(cString: nl_langinfo(CODESET))
    }

    private static func scratch(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-locale-\(suffix)-\(UUID().uuidString)")
    }

    private static let chineseFile = "目录/café-中文.txt"
    private static let otherFile = "данные/表情-🙂.bin"
    private static let chineseLink = "链接-é"
    private static let otherLink = "lien-данные"

    private static func makeUnicodeTree() throws -> URL {
        let root = scratch("tree")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("目录"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("данные"), withIntermediateDirectories: true)
        try Data("bonjour\n".utf8).write(to: root.appendingPathComponent(chineseFile))
        try Data(repeating: 0xA5, count: 70_000).write(to: root.appendingPathComponent(otherFile))
        try manager.createSymbolicLink(
            atPath: root.appendingPathComponent(chineseLink).path,
            withDestinationPath: chineseFile,
        )
        try manager.createSymbolicLink(
            atPath: root.appendingPathComponent(otherLink).path,
            withDestinationPath: otherFile,
        )
        return root
    }

    /// A zip written with the UTF-8 name flag (general purpose bit 11), the
    /// case libarchive converts instead of passing the bytes through. Neither
    /// ditto nor /usr/bin/zip sets that flag, so the fixture is written here,
    /// in a UTF-8 locale. The layout is an IPA's.
    private func makeUTF8Zip(at zip: URL, files: [(String, Data)], links: [(String, String)] = []) throws {
        try inLocale("UTF-8") {
            let writer = archive_write_new()
            defer { archive_write_free(writer) }
            archive_write_set_format_zip(writer)
            try #require(archive_write_set_options(writer, "zip:hdrcharset=UTF-8") == ARCHIVE_OK)
            try #require(archive_write_open_filename(writer, zip.path) == ARCHIVE_OK)
            for (name, data) in files {
                let entry = archive_entry_new()
                defer { archive_entry_free(entry) }
                archive_entry_set_pathname(entry, name)
                archive_entry_set_filetype(entry, UInt32(S_IFREG))
                archive_entry_set_perm(entry, 0o644)
                archive_entry_set_size(entry, la_int64_t(data.count))
                try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
                let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                #expect(written == data.count)
            }
            for (name, target) in links {
                let entry = archive_entry_new()
                defer { archive_entry_free(entry) }
                archive_entry_set_pathname(entry, name)
                archive_entry_set_filetype(entry, UInt32(S_IFLNK))
                archive_entry_set_perm(entry, 0o755)
                archive_entry_set_symlink(entry, target)
                try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
            }
            try #require(archive_write_close(writer) == ARCHIVE_OK)
        }
        // General purpose flags are at +6 of the first local header; bit 11 is
        // byte 7, bit 3.
        let header = try [UInt8](Data(contentsOf: zip).prefix(8))
        try #require(header[0 ..< 4] == [0x50, 0x4B, 0x03, 0x04])
        try #require(header[7] & 0x08 != 0)
    }

    // MARK: - Round trips

    @Test(arguments: [VPhoneArchiveFormat.gnutar, .pax, .ustar])
    func `non-ASCII names and link targets round trip in the C locale`(format: VPhoneArchiveFormat) throws {
        let source = try Self.makeUnicodeTree()
        let archive = Self.scratch("tar").appendingPathExtension("tar")
        let destination = Self.scratch("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let (count, entries, first, second) = try inLocale("C") {
            let count = try VPhoneArchiveWriter.create(archive: archive, from: source, format: format)
            let entries = try VPhoneArchiveReader.entries(of: archive)
            let first = try VPhoneArchiveReader.readMember(Self.chineseFile, from: archive)
            let second = try VPhoneArchiveReader.readMember(Self.otherFile, from: archive)
            try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            return (count, entries, first, second)
        }

        #expect(count == 6)
        #expect(Set(entries.map(\.path)) == [
            "目录/", Self.chineseFile, "данные/", Self.otherFile, Self.chineseLink, Self.otherLink,
        ])
        #expect(entries.first { $0.path == Self.chineseLink }?.linkTarget == Self.chineseFile)
        #expect(entries.first { $0.path == Self.otherLink }?.linkTarget == Self.otherFile)
        #expect(String(decoding: first, as: UTF8.self) == "bonjour\n")
        #expect(second == Data(repeating: 0xA5, count: 70_000))

        #expect(try String(
            contentsOf: destination.appendingPathComponent(Self.chineseFile), encoding: .utf8,
        ) == "bonjour\n")
        #expect(try Data(contentsOf: destination.appendingPathComponent(Self.otherFile)).count == 70_000)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent(Self.chineseLink).path,
        ) == Self.chineseFile)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent(Self.otherLink).path,
        ) == Self.otherFile)
    }

    @Test
    func `a UTF-8 flagged IPA-shaped zip is listed, read and unpacked in the C locale`() throws {
        let zip = Self.scratch("ipa").appendingPathExtension("ipa")
        let destination = Self.scratch("ipa-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [zip, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let plist = "Payload/应用.app/Info.plist"
        let resource = "Payload/应用.app/资源/данные-🙂.txt"
        let link = "Payload/应用.app/链接"
        let linkTarget = "资源/данные-🙂.txt"
        try makeUTF8Zip(
            at: zip,
            files: [(plist, Data("<plist/>\n".utf8)), (resource, Data("données\n".utf8))],
            links: [(link, linkTarget)],
        )

        // Each step on its own, so a failure names the step.
        let entries = try inLocale("C") { try VPhoneArchiveReader.entries(of: zip) }
        #expect(Set(entries.map(\.path)) == [plist, resource, link])
        #expect(entries.first { $0.path == link }?.linkTarget == linkTarget)

        let data = try inLocale("C") { try VPhoneArchiveReader.readMember(plist, from: zip) }
        #expect(String(decoding: data, as: UTF8.self) == "<plist/>\n")

        let written = try inLocale("C") {
            try VPhoneArchiveExtractor.extract(zip, into: destination, options: .intoHostDirectory)
        }
        #expect(written == 3)
        var info = stat()
        #expect(lstat(destination.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR)
        #expect(try String(contentsOf: destination.appendingPathComponent(plist), encoding: .utf8) == "<plist/>\n")
        #expect(try String(contentsOf: destination.appendingPathComponent(resource), encoding: .utf8) == "données\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent(link).path,
        ) == linkTarget)
    }

    // MARK: - Failure paths

    /// A name libarchive cannot convert comes back as a NULL pathname. Read as
    /// "", it resolves to the destination itself and passes the containment
    /// check, so the entry would be written over the destination directory.
    /// Invalid UTF-8 in a UTF-8 flagged name cannot be converted in any
    /// locale, so this stays a failure after the locale fix.
    @Test
    func `an entry whose name cannot be converted is refused, not written over the destination`() throws {
        let zip = Self.scratch("bad").appendingPathExtension("zip")
        let destination = Self.scratch("bad-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [zip, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Non-ASCII, or libarchive does not set the UTF-8 flag at all.
        let name = "坏-#.txt"
        try makeUTF8Zip(at: zip, files: [(name, Data("payload\n".utf8))])
        // Replace '#' with 0xFF in the local header and the central directory.
        // Zip CRCs cover member data only, so the name can be patched in place.
        var bytes = try [UInt8](Data(contentsOf: zip))
        let needle = Array(name.utf8)
        let hash = try #require(needle.firstIndex(of: UInt8(ascii: "#")))
        var patched = 0
        var index = 0
        while index + needle.count <= bytes.count {
            if Array(bytes[index ..< index + needle.count]) == needle {
                bytes[index + hash] = 0xFF
                patched += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        try #require(patched == 2)
        try Data(bytes).write(to: zip)

        for locale in ["C", "UTF-8"] {
            #expect(throws: VPhoneArchiveError.self) {
                try inLocale(locale) {
                    try VPhoneArchiveExtractor.extract(zip, into: destination, options: .intoHostDirectory)
                }
            }
            var info = stat()
            #expect(lstat(destination.path, &info) == 0)
            #expect((info.st_mode & S_IFMT) == S_IFDIR)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test
    func `a missing non-ASCII member is reported by name in the C locale`() throws {
        let source = try Self.makeUnicodeTree()
        let archive = Self.scratch("missing").appendingPathExtension("tar")
        defer {
            for url in [source, archive] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try inLocale("C") {
            try VPhoneArchiveWriter.create(archive: archive, from: source, format: .pax)
            do {
                _ = try VPhoneArchiveReader.readMember("目录/不存在.txt", from: archive)
                Issue.record("reading a missing member succeeded")
            } catch let VPhoneArchiveError.memberNotFound(member, _) {
                #expect(member == "目录/不存在.txt")
            }
        }
    }

    // MARK: - Locale isolation

    /// Every archive call, succeeding or failing, leaves the calling thread on
    /// the locale object it had before.
    @Test
    func `archive calls restore the calling thread's locale, including on failure`() throws {
        let source = try Self.makeUnicodeTree()
        let archive = Self.scratch("restore").appendingPathExtension("tar")
        let destination = Self.scratch("restore-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            for url in [source, archive, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try inLocale("C") {
            let before = uselocale(nil)
            let codeset = Self.threadCodeset()
            let check = { (step: String) in
                #expect(uselocale(nil) == before, "locale object changed after \(step)")
                #expect(Self.threadCodeset() == codeset, "codeset changed after \(step)")
            }

            try VPhoneArchiveWriter.create(archive: archive, from: source, format: .pax)
            check("create")
            _ = try VPhoneArchiveReader.entries(of: archive)
            check("entries")
            _ = try VPhoneArchiveReader.readMember(Self.chineseFile, from: archive)
            check("readMember")
            _ = try VPhoneArchiveReader.describe(archive)
            check("describe")
            try VPhoneArchiveExtractor.extract(archive, into: destination, options: .intoHostDirectory)
            check("extract")

            let missing = Self.scratch("absent").appendingPathExtension("tar")
            #expect(throws: VPhoneArchiveError.self) { try VPhoneArchiveReader.entries(of: missing) }
            check("failed entries")
            #expect(throws: VPhoneArchiveError.self) {
                try VPhoneArchiveReader.readMember("不存在", from: archive)
            }
            check("failed readMember")
            #expect(throws: VPhoneArchiveError.self) {
                try VPhoneArchiveExtractor.extract(missing, into: destination, options: .intoHostDirectory)
            }
            check("failed extract")
            #expect(throws: VPhoneArchiveError.self) {
                try VPhoneArchiveWriter.create(archive: archive, from: source, format: .pax)
            }
            check("failed create")
        }
    }

    /// Inside the wrapper this thread is UTF-8 while a thread without its own
    /// locale, sampled at that moment, still sees the process locale. After
    /// it, returning or throwing, this thread is back on its own locale.
    @Test
    func `withArchiveLocale changes only the calling thread, and only inside the call`() throws {
        struct Planned: Error {}
        try inLocale("C") {
            let before = uselocale(nil)
            let codeset = Self.threadCodeset()
            #expect(codeset != "UTF-8")
            let global = String(cString: setlocale(LC_CTYPE, nil))

            let (inside, elsewhere) = withArchiveLocale {
                (Self.threadCodeset(), CodesetObserver.sampleOnAnotherThread())
            }
            #expect(inside == "UTF-8")
            #expect(elsewhere == CodesetObserver.sampleOnAnotherThread())
            #expect(String(cString: setlocale(LC_CTYPE, nil)) == global)
            #expect(uselocale(nil) == before)
            #expect(Self.threadCodeset() == codeset)

            #expect(throws: Planned.self) {
                try withArchiveLocale {
                    #expect(Self.threadCodeset() == "UTF-8")
                    throw Planned()
                }
            }
            #expect(uselocale(nil) == before)
            #expect(Self.threadCodeset() == codeset)
        }
    }

    /// Archive work on one thread does not change the locale another thread
    /// sees, and does not change the process-wide locale.
    @Test
    func `archive calls do not change other threads or the global locale`() throws {
        let source = try Self.makeUnicodeTree()
        defer { try? FileManager.default.removeItem(at: source) }

        let global = String(cString: setlocale(LC_CTYPE, nil))
        let observer = CodesetObserver()
        observer.start()
        try inLocale("C") {
            for round in 0 ..< 8 {
                let archive = Self.scratch("iso-\(round)").appendingPathExtension("tar")
                defer { try? FileManager.default.removeItem(at: archive) }
                try VPhoneArchiveWriter.create(archive: archive, from: source, format: .pax)
                _ = try VPhoneArchiveReader.entries(of: archive)
                _ = try VPhoneArchiveReader.readMember(Self.otherFile, from: archive)
            }
        }
        let seen = observer.stop()

        #expect(String(cString: setlocale(LC_CTYPE, nil)) == global)
        #expect(seen.samples > 0)
        #expect(seen.codesets == [seen.initial])
    }
}

/// Samples the LC_CTYPE codeset a thread with no per-thread locale sees, until
/// told to stop.
final class CodesetObserver: @unchecked Sendable {
    struct Result {
        let initial: String
        let codesets: Set<String>
        let samples: Int
    }

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var running = true
    private var initial = ""
    private var codesets: Set<String> = []
    private var samples = 0

    func start() {
        Thread { [self] in
            let first = String(cString: nl_langinfo(CODESET))
            lock.withLock { initial = first }
            ready.signal()
            while lock.withLock({ running }) {
                let codeset = String(cString: nl_langinfo(CODESET))
                lock.withLock {
                    codesets.insert(codeset)
                    samples += 1
                }
            }
            finished.signal()
        }.start()
        ready.wait()
    }

    func stop() -> Result {
        lock.withLock { running = false }
        finished.wait()
        return lock.withLock { Result(initial: initial, codesets: codesets, samples: samples) }
    }

    /// The codeset a new thread sees, read while the caller waits.
    static func sampleOnAnotherThread() -> String {
        let observer = CodesetObserver()
        observer.start()
        return observer.stop().initial
    }
}
