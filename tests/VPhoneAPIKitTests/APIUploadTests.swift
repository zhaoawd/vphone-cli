import Darwin
import Foundation
import XCTest
@testable import VPhoneAPIKit

@MainActor
final class APIUploadTests: XCTestCase {
    func testSnapshotUploadBytesModeAndIdentity() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        let client = try fixture.client()
        let health = try await client.health()
        let path = fixture.directory.appendingPathComponent("source")
        let bytes = Data(repeating: 253, count: 2 * 1024 * 1024)
        try bytes.write(to: path)
        let source = try await VPhoneAPIUpload.prepare(path: path.path)
        try Data("changed".utf8).write(to: path)
        try await client.uploadFile(source, path: "/中文+ file", permissions: "640",
            instanceID: XCTUnwrap(health.instanceID), binaryHash: health.binaryHash, timeout: 2)
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("uploaded")), bytes)
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("uploaded-mode"), encoding: .utf8), "640")
        do {
            try await client.uploadFile(VPhoneAPIUpload.prepare(data: Data([1])), path: "/x", permissions: "644", instanceID: UUID().uuidString, binaryHash: health.binaryHash, timeout: 2)
            XCTFail("Stale identity accepted")
        } catch let error as VPhoneAPIError { XCTAssertEqual(error.code, "http") }
        for path in ["/redirect-upload", "/lost-reply"] {
            do {
                try await client.uploadFile(source, path: path, permissions: "600", instanceID: XCTUnwrap(health.instanceID), binaryHash: health.binaryHash, timeout: 2)
                XCTFail("Expected \(path) to fail")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("followed").path))
    }

    func testSourcesAreBoundedRegularFilesAndInlineAcceptsEmpty() async throws {
        XCTAssertEqual(try VPhoneAPIUpload.prepare(data: Data()).size, 0)
        XCTAssertThrowsError(try VPhoneAPIUpload.prepare(data: Data(count: 1024 * 1024 + 1)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("upload-source-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appendingPathComponent("large")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [large.path, link.path, fifo.path, directory.path] {
            do { _ = try await VPhoneAPIUpload.prepare(path: path); XCTFail("Accepted non-source \(path)") } catch {}
        }
    }
}
