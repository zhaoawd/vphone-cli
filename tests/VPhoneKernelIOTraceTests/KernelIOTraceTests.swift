import Darwin
import Foundation
import XCTest
@testable import VPhoneKernelIOTrace

final class KernelIOTraceTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-io-trace-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func events(_ prefix: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: prefix.path + ".\(getpid()).jsonl"))
        return try data.split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
    func testDisabledRecorderHasNoOutputAndIdenticalBusinessOrder() throws {
        try temporary { root in
            let recorder = KernelIORecorder(outputPrefix: nil)
            var order: [String] = []
            let result = recorder.measure("outer") { span in
                XCTAssertNil(span); order.append("intent"); order.append("write"); order.append("sync"); order.append("cursor"); return 17
            }
            recorder.flush()
            XCTAssertEqual(result, 17); XCTAssertEqual(order, ["intent", "write", "sync", "cursor"])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    func testEnabledRecorderBuffersUntilTerminalFlushAndPreservesOrder() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            var order: [String] = []
            let result = try recorder.measure("outer", aggregateChildren: true) { span in
                order.append("intent")
                try recorder.measure("journal", aggregate: true) { _ in
                    order.append("write")
                    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
                    order.append("sync")
                }
                span?.set("bytes", 3); order.append("cursor")
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
                return 17
            }
            XCTAssertEqual(result, 17); XCTAssertEqual(order, ["intent", "write", "sync", "cursor"])
            recorder.flush(); recorder.flush()
            let rows = try events(prefix)
            XCTAssertEqual(rows.count, 2)
            let counts = try XCTUnwrap(rows[0]["counts"] as? [String: Int64])
            XCTAssertEqual(counts["bytes"], 3); XCTAssertEqual(counts["aggregate.journal.calls"], 1)
            XCTAssertEqual(rows.last?["complete"] as? Bool, true)
        }
    }
    func testNestedSpansHaveParentContainmentAndCaller() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            recorder.measure("parent", file: "test/Caller.swift", line: 123, function: "testCaller") { _ in recorder.measure("child") { $0?.set("bytes", 5) } }
            recorder.flush(); let rows = try events(prefix)
            let child = try XCTUnwrap(rows.first(where: { $0["phase"] as? String == "child" }))
            let parent = try XCTUnwrap(rows.first(where: { $0["phase"] as? String == "parent" }))
            XCTAssertEqual(child["parent_id"] as? String, parent["id"] as? String)
            XCTAssertEqual(parent["caller_file"] as? String, "test/Caller.swift"); XCTAssertEqual(parent["caller_line"] as? Int, 123)
            let ps = try XCTUnwrap(parent["started_ns"] as? UInt64), cs = try XCTUnwrap(child["started_ns"] as? UInt64)
            XCTAssertGreaterThanOrEqual(cs, ps)
            XCTAssertLessThanOrEqual(cs + (child["elapsed_ns"] as! UInt64), ps + (parent["elapsed_ns"] as! UInt64))
        }
    }
    func testOriginalThrownObjectAndParentStackArePreserved() throws {
        final class Expected: Error {}
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            let expected = Expected()
            do { try recorder.measure("failure") { _ -> Void in throw expected }; XCTFail("Expected error") }
            catch { XCTAssertTrue((error as AnyObject) === expected) }
            recorder.measure("next") { _ in () }; recorder.flush()
            let rows = try events(prefix)
            XCTAssertEqual(rows[0]["outcome"] as? String, "error"); XCTAssertNil(rows[1]["parent_id"])
            XCTAssertEqual(rows.last?["open_spans"] as? Int, 0); XCTAssertEqual(rows.last?["complete"] as? Bool, true)
        }
    }
    func testFsyncFailurePreservesReturnAndErrnoWithoutFakingBytes() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            errno = 0
            XCTAssertEqual(recorder.synchronize(-1, phase: "fsync", file: #fileID, line: #line, function: #function), -1)
            XCTAssertEqual(errno, EBADF)
            recorder.flush(); let rows = try events(prefix)
            XCTAssertEqual(rows[0]["outcome"] as? String, "error")
            XCTAssertEqual((rows[0]["labels"] as? [String: String])?["error_code"], String(EBADF))
            XCTAssertNil((rows[0]["counts"] as? [String: Int64])?["bytes"])
        }
    }
    func testFsyncSuccessOnOrdinaryFileDoesNotWriteTraceInScope() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            let path = root.appendingPathComponent("ordinary"); try Data([1, 2, 3]).write(to: path)
            let fd = open(path.path, O_RDONLY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            XCTAssertEqual(recorder.synchronize(fd, phase: "fsync", file: #fileID, line: #line, function: #function), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path + ".\(getpid()).jsonl"))
            recorder.flush(); let rows = try events(prefix)
            XCTAssertEqual(rows[0]["outcome"] as? String, "success")
            XCTAssertNil((rows[0]["counts"] as? [String: Int64])?["errno"])
        }
    }
    func testFsyncSuccessPreservesEntryErrnoLikeNativeCall() throws {
        try temporary { root in
            let recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path)
            let path = root.appendingPathComponent("ordinary"); try Data([1, 2, 3]).write(to: path)
            let fd = open(path.path, O_RDONLY | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            errno = E2BIG
            let nativeResult = Darwin.fsync(fd), nativeErrno = errno
            XCTAssertEqual(nativeResult, 0)
            errno = E2BIG
            let measuredResult = recorder.synchronize(fd, phase: "fsync", file: #fileID, line: #line, function: #function)
            let measuredErrno = errno
            XCTAssertEqual(measuredResult, nativeResult); XCTAssertEqual(measuredErrno, nativeErrno)
            // Includes the public wrapper's first-access/lazy-recorder path.
            errno = E2BIG
            let publicResult = KernelIOTrace.synchronize(fd)
            let publicErrno = errno
            XCTAssertEqual(publicResult, nativeResult); XCTAssertEqual(publicErrno, nativeErrno)
            recorder.flush()
        }
    }
    func testBoundedBufferMarksIncompleteWithoutChangingResult() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), recorder = KernelIORecorder(outputPrefix: root.appendingPathComponent("trace").path, maximumEvents: 1)
            XCTAssertEqual(recorder.measure("one") { _ in 1 }, 1); XCTAssertEqual(recorder.measure("two") { _ in 2 }, 2)
            recorder.flush(); let rows = try events(prefix)
            XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.last?["complete"] as? Bool, false); XCTAssertEqual(rows.last?["dropped"] as? Int, 1)
        }
    }
    func testOutputFailureDoesNotThrowOrOverwrite() throws {
        try temporary { root in
            let prefix = root.appendingPathComponent("trace"), output = root.appendingPathComponent("trace.\(getpid()).jsonl")
            try Data("previous".utf8).write(to: output)
            let recorder = KernelIORecorder(outputPrefix: prefix.path)
            XCTAssertEqual(recorder.measure("one") { _ in 9 }, 9); recorder.flush()
            XCTAssertEqual(try Data(contentsOf: output), Data("previous".utf8))
        }
    }
}
