import Foundation
import Testing
@testable import VPhoneSign

struct VPhoneSignIntegrationTests {
    @Test func existingSiblingTemporaryIsPreserved() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignFixtures.copy(
            VPhoneSignFixtures.url("hello-arm64"), into: directory, as: "binary")
        let sibling = directory.appendingPathComponent(".binary.vphonesign")
        let sentinel = Data("unrelated file".utf8)
        try sentinel.write(to: sibling)
        try VPhoneSigner.sign(fileAt: file)
        #expect(try Data(contentsOf: sibling) == sentinel)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == ["binary", ".binary.vphonesign"])
    }

    @Test func symbolicLinkIsRefusedWithoutChangingItsTarget() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignFixtures.copy(
            VPhoneSignFixtures.url("hello-arm64"), into: directory, as: "binary")
        let before = try Data(contentsOf: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: VPhoneSignError.self) { try VPhoneSigner.sign(fileAt: link) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
    }

    @Test func malformedPKCS12IsRefused() {
        #expect(throws: VPhoneSignError.self) {
            try VPhoneSignIdentity(pkcs12: Data([0x30, 0xff]), password: "")
        }
    }

    @Test func repositoryIdentityProducesVerifiableCMS() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = VPhoneSignFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        let p12 = try Data(contentsOf: repo.appendingPathComponent("scripts/vphoned/signcert.p12"))
        let identity = try VPhoneSignIdentity(pkcs12: p12, password: "")
        let file = try VPhoneSignFixtures.sign(
            VPhoneSignFixtures.url("hello-arm64"), in: directory, identity: identity)
        for (index, slice) in try VPhoneSignBlobs(fileAt: file).slices.enumerated() {
            let codeDirectory = try #require(slice[0])
            let wrapper = try #require(slice[0x10000])
            #expect(wrapper.count > 8)
            let cms = directory.appendingPathComponent("cms-\(index).der")
            let content = directory.appendingPathComponent("cd-\(index).bin")
            try Data(wrapper.dropFirst(8)).write(to: cms)
            try codeDirectory.write(to: content)
            let result = try VPhoneSignFixtures.run(URL(fileURLWithPath: "/usr/bin/openssl"), [
                "cms", "-verify", "-binary", "-inform", "DER", "-in", cms.path,
                "-content", content.path, "-noverify", "-out", "/dev/null",
            ])
            #expect(result.status == 0, "CMS signature check: \(result.error)")
        }
    }

    @Test func appleAdHocExecutableRunsOnHost() throws {
        let directory = try VPhoneSignFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignFixtures.sign(
            VPhoneSignFixtures.url("hello-arm64"), in: directory, style: .appleAdHoc)
        let result = try VPhoneSignFixtures.run(file, [])
        #expect(result.status == 0, "\(result.error)")
        #expect(!result.out.isEmpty)
    }
}
