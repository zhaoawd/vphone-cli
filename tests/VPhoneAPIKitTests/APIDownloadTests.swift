import Foundation
import XCTest
@testable import VPhoneAPIKit

@MainActor
final class APIDownloadTests: XCTestCase {
    private func receive(_ fixture: APIHTTPFixture, _ path: String, limit: Int = 1024 * 1024,
                         timeout: TimeInterval = 5) async throws -> VPhoneAPIDownload {
        let client = try fixture.client(timeout: timeout)
        let health = try await client.health()
        return try await client.downloadFile(path: path, instanceID: XCTUnwrap(health.instanceID),
            binaryHash: health.binaryHash, maximumBytes: limit, stagingDirectory: fixture.directory)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func staged(_ fixture: APIHTTPFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).filter { $0.hasPrefix(".vphone-download-") }
    }

    func testBinaryEmptyQueryEncodingAndInlineBoundary() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        for path in ["/中文 a?&+%.bin", "/bytes/0", "/bytes/1048576"] {
            let file = try await receive(fixture, path)
            let bytes = try file.data()
            XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("download-path"), encoding: .utf8), path)
            if path == "/bytes/0" { XCTAssertTrue(bytes.isEmpty) }
            else { XCTAssertEqual(Array(bytes.prefix(256)), Array(UInt8.min...UInt8.max)) }
            XCTAssertEqual(bytes.count, file.size)
        }
        XCTAssertTrue(try staged(fixture).isEmpty)
    }

    func testStreamedSaveIsExclusiveAndPrivate() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        let file = try await receive(fixture, "/bytes/67108864", limit: 64 * 1024 * 1024)
        XCTAssertEqual(file.size, 64 * 1024 * 1024)
        XCTAssertThrowsError(try file.data())
        let destination = fixture.directory.appendingPathComponent("saved")
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try file.publish(to: destination)) { error in
            XCTAssertEqual((error as? VPhoneAPIError)?.code, "destination_exists")
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        let symlink = fixture.directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        XCTAssertThrowsError(try file.publish(to: symlink))
        let saved = fixture.directory.appendingPathComponent("new-file")
        try file.publish(to: saved)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        XCTAssertEqual(attributes[.size] as? Int, 64 * 1024 * 1024)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testErrorsAndChunkedLimitsRemoveAllStaging() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        for (path, code) in [("/wrong-instance", "identity_mismatch"), ("/wrong-hash", "identity_mismatch"),
                             ("/wrong-type", "protocol"), ("/redirect-file", "http"), ("/missing", "http"),
                             ("/bytes/1048577", "file_too_large"), ("/chunked/1048577", "file_too_large")] {
            do { _ = try await receive(fixture, path); XCTFail("Accepted \(path)") }
            catch let error as VPhoneAPIError { XCTAssertEqual(error.code, code, path) }
            XCTAssertTrue(try staged(fixture).isEmpty, path)
        }
        let valid = try await receive(fixture, "/chunked/1048576")
        XCTAssertEqual(valid.size, 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("followed").path))
        do { _ = try await receive(fixture, "/short"); XCTFail("Accepted truncated file") } catch {}
        // Only the successful chunked result is still owned by this test.
        XCTAssertEqual(try staged(fixture).count, 1)
    }

    func testCancellationDeadlineAndSessionStopCleanPartialFiles() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        let session = VPhoneAPISession(client: try fixture.client(timeout: 10), vmInstanceID: "download-vm")
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .ready }
        let jobs = (0..<4).map { index in Task {
            try await session.downloadFile(path: "/slow-file\(index)", maximumBytes: 1024, stagingDirectory: fixture.directory)
        } }
        try await wait { (0..<4).allSatisfy {
            FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started-slow-file\($0)").path)
        } }
        do {
            _ = try await session.downloadFile(path: "/bytes/0", maximumBytes: 1024, stagingDirectory: fixture.directory)
            XCTFail("Accepted fifth download")
        } catch let error as VPhoneAPIError { XCTAssertEqual(error.code, "busy") }
        session.stop()
        for job in jobs { do { _ = try await job.value; XCTFail("Stopped transfer succeeded") } catch {} }
        XCTAssertTrue(try staged(fixture).isEmpty)
        do { _ = try await receive(fixture, "/slow-file-timeout", timeout: 0.05); XCTFail("Expected timeout") }
        catch let error as VPhoneAPIError { XCTAssertEqual(error.code, "timeout") }
        XCTAssertTrue(try staged(fixture).isEmpty)
        let job = Task { try await receive(fixture, "/slow-file-cancel") }
        try await wait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started-slow-file-cancel").path) }
        job.cancel()
        do { _ = try await job.value; XCTFail("Cancelled transfer succeeded") } catch {}
        XCTAssertTrue(try staged(fixture).isEmpty)
    }
}
