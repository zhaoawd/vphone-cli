import Darwin
import Foundation
import Testing
@testable import VPhoneArchiveKit

struct ArchiveWorkingDirectoryTests {
    @Test(arguments: [false, true])
    func writingArchivesKeepsTheProcessWorkingDirectory(cancel: Bool) throws {
        let fm = FileManager.default
        let original = fm.currentDirectoryPath
        let originalFD = open(".", O_RDONLY | O_DIRECTORY)
        try #require(originalFD >= 0)
        defer { _ = fchdir(originalFD); close(originalFD) }
        let root = fm.temporaryDirectory.appendingPathComponent("archive-cwd-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        for index in 0 ..< 1000 {
            let directory = source.appendingPathComponent("dir-\(index / 20)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directory.appendingPathComponent("file-\(index)"))
        }
        let observer = WorkingDirectoryObserver(expected: original)
        observer.start()
        defer { observer.stop() }
        let archive = root.appendingPathComponent("out.tar")
        var entries = 0
        let write = {
            try VPhoneArchiveWriter.create(archive: archive, from: source,
                                           progress: { entries = $0.entriesWritten },
                                           isCancelled: { cancel && entries >= 5 })
        }
        if cancel {
            let error = #expect(throws: VPhoneArchiveError.self) { try write() }
            if case .cancelled? = error {} else { Issue.record("expected archive cancellation") }
            #expect(try fm.contentsOfDirectory(atPath: root.path) == ["source"])
        } else {
            _ = try write()
        }
        observer.stop()
        #expect(observer.changes.isEmpty, "archive traversal changed the process working directory")
        #expect(fm.currentDirectoryPath == original)
    }
}

private final class WorkingDirectoryObserver: @unchecked Sendable {
    private let expected: String
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var stopping = false
    private var stopped = false
    private var observed = Set<String>()

    init(expected: String) { self.expected = expected }
    var changes: Set<String> { lock.withLock { observed } }
    func start() {
        Thread.detachNewThread { [self] in
            ready.signal()
            while !lock.withLock({ stopping }) {
                let current = FileManager.default.currentDirectoryPath
                if current != expected { lock.withLock { _ = observed.insert(current) } }
            }
            finished.signal()
        }
        ready.wait()
    }
    func stop() {
        let shouldWait = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            stopping = true
            return true
        }
        if shouldWait { finished.wait() }
    }
}
