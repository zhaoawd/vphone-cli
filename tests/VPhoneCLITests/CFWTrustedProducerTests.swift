import CryptoKit
import Darwin
import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

final class CFWTrustedProducerTests: XCTestCase {
    func testOnlyAnActiveRootQualifiedProducerAncestorQualifies() throws {
        let executable = URL(fileURLWithPath: "/verified/Contents/MacOS/vphone-cli")
        let parents: [pid_t: pid_t] = [100: 90, 90: 40, 40: 1]
        var arguments: [String] = [executable.path, "cfw", "install", "vm", "--qualify-origin"]
        var uid: uid_t = 0
        var zombie = false
        func identity(_ pid: pid_t) -> VPhoneProcessIdentity? {
            .init(pid: pid, startedAt: 1, uid: uid, isZombie: zombie)
        }
        func qualifies() -> Bool {
            VPhoneCFWTrustedProducer.qualifiedAncestor(start: 100, executable: executable, parents: parents,
                identity: identity, arguments: { $0 == 40 ? arguments : ["/usr/bin/python3"] })
        }
        XCTAssertTrue(qualifies())
        uid = 501; XCTAssertFalse(qualifies()); uid = 0
        zombie = true; XCTAssertFalse(qualifies()); zombie = false
        arguments.removeLast(); XCTAssertFalse(qualifies())
        arguments = [executable.path, "cfw", "verify-origin-source"]; XCTAssertFalse(qualifies())
        arguments = [executable.path, "cfw", "recover-origin", "vm"]; XCTAssertTrue(qualifies())
        var reads = 0
        XCTAssertFalse(VPhoneCFWTrustedProducer.qualifiedAncestor(start: 40, executable: executable, parents: parents,
            identity: { pid in reads += 1; return .init(pid: pid, startedAt: Double(reads), uid: 0) },
            arguments: { _ in arguments }))
    }

    func testSourceQualificationRefusesProducerResourceOverrides() throws {
        try VPhoneCFWTrustedProducer.requireDefaultResources(projectRoot: nil, environment: [:])
        XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireDefaultResources(projectRoot: "/tmp", environment: [:]))
        for name in ["VPHONE_PYTHON", "VPHONE_VENV_DIR", "VPHONE_HOST_PYTHON", "VPHONE_GUEST_COMPONENTS", "VPHONE_API_DAEMON"] {
            XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireDefaultResources(projectRoot: nil, environment: [name: "/foreign"]))
        }
    }

    func testAttestationRequiresExactOwnerModeBytesAndAnUnlinkedCanonicalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("guest-origin-attestation.json")
        let data = Data("bound transaction proof".utf8)
        try data.write(to: path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(chmod(path.path, 0o444), 0)
        try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: digest, owner: geteuid())
        if geteuid() != 0 { XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: digest)) }
        XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: String(repeating: "a", count: 64), owner: geteuid()))
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: digest, owner: geteuid()))
        XCTAssertEqual(chmod(path.path, 0o444), 0)
        try FileManager.default.linkItem(at: path, to: directory.appendingPathComponent("shared"))
        XCTAssertThrowsError(try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: digest, owner: geteuid()))
    }

    func testRecoveryRejectsTraversalAndInstallAcceptsOnlyAnExplicitQualificationFlag() throws {
        let parsed = try VPhoneCFWInstallCommand.parse(["vm", "--qualify-origin"])
        XCTAssertTrue(parsed.qualifyOrigin)
        for name in ["../elsewhere", ".cfw_disk.x/../other", ".cfw_disk.", "other"] {
            XCTAssertThrowsError(try VPhoneCFWRecoverOriginCommand.parse(["vm", "--transaction", name]))
        }
        _ = try VPhoneCFWRecoverOriginCommand.parse(["vm", "--transaction", ".cfw_disk.exact"])
    }

    func testAttestationAcceptsACompleteBlobIndexLargerThan128KiB() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("guest-origin-attestation.json")
        let data = Data(repeating: 0x61, count: 512 * 1024)
        try data.write(to: path)
        XCTAssertEqual(chmod(path.path, 0o444), 0)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try VPhoneCFWTrustedProducer.requireAttestation(path, sha256: digest, owner: geteuid())
    }
}
