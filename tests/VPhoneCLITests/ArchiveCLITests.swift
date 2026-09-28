import ArgumentParser
import Testing
@testable import vphone_cli

struct ArchiveCLITests {
    @Test func archiveCommandsAreRegistered() throws {
        #expect(try VPhoneCLI.parseAsRoot(["archive", "-f", "/tmp/sample.tar"]) is VPhoneArchiveExtractCommand)
        #expect(try VPhoneCLI.parseAsRoot(["archive", "create", "-f", "/tmp/sample.tar"]) is VPhoneArchiveCreateCommand)
        #expect(try VPhoneCLI.parseAsRoot(["archive", "list", "-f", "/tmp/sample.tar"]) is VPhoneArchiveListCommand)
        #expect(try VPhoneCLI.parseAsRoot(["archive", "cat", "-f", "/tmp/sample.tar", "member"]) is VPhoneArchiveCatCommand)
        #expect(try VPhoneCLI.parseAsRoot(["archive", "decompress", "-f", "/tmp/sample.tzst", "-o", "/tmp/sample.tar"]) is VPhoneArchiveDecompressCommand)
        #expect(try VPhoneCLI.parseAsRoot(["archive", "fingerprint", "/tmp/tree"]) is VPhoneArchiveFingerprintCommand)
    }

    @Test(arguments: [["--zstd", "--xz"], ["--format", "unknown"]])
    func invalidCreateOptionsAreRejected(options: [String]) {
        #expect(throws: (any Error).self) {
            try VPhoneArchiveCreateCommand.parse(["-f", "/tmp/sample.tar"] + options)
        }
    }
}
