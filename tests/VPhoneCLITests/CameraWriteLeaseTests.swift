import Darwin
import XCTest
@testable import vphone_cli

final class CameraWriteLeaseTests: XCTestCase {
    func testQueuedWriterKeepsOriginalPipeAfterDescriptorNumberIsReused() throws {
        var old = [Int32](repeating: -1, count: 2), new = old
        XCTAssertEqual(pipe(&old), 0); XCTAssertEqual(pipe(&new), 0)
        defer { close(old[0]); close(old[1]); close(new[0]); close(new[1]) }
        var lease = try XCTUnwrap(VPhoneCameraWriteLease.acquire(old[1])) as VPhoneCameraWriteLease?
        let owned = lease!.fileDescriptor
        XCTAssertNotEqual(owned, old[1])
        close(old[1])
        XCTAssertEqual(dup2(new[1], old[1]), old[1])
        var byte: UInt8 = 42
        XCTAssertEqual(Darwin.write(owned, &byte, 1), 1)
        _ = fcntl(old[0], F_SETFL, O_NONBLOCK); _ = fcntl(new[0], F_SETFL, O_NONBLOCK)
        var received: UInt8 = 0
        XCTAssertEqual(Darwin.read(old[0], &received, 1), 1); XCTAssertEqual(received, 42)
        XCTAssertEqual(Darwin.read(new[0], &received, 1), -1); XCTAssertEqual(errno, EAGAIN)
        lease = nil
        XCTAssertEqual(fcntl(owned, F_GETFD), -1); XCTAssertEqual(errno, EBADF)
    }
    func testClosedDescriptorCannotBeLeased() {
        XCTAssertNil(VPhoneCameraWriteLease.acquire(-1))
    }
}
