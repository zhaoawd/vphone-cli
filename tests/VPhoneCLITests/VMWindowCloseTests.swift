import AppKit
import XCTest
@testable import vphone_cli

@MainActor
private final class ShutdownDelegateSpy: VPhoneAppDelegate {
    var requests = 0
    // Exercise the real writer admission path; replace only the handoff to
    // Virtualization.framework/AppKit termination so no VM starts or exits.
    override func handleDrainedInterrupt() { requests += 1 }
}

@MainActor
final class VMWindowCloseTests: XCTestCase {
    private func waitForRequests(_ count: Int, from delegate: ShutdownDelegateSpy) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while delegate.requests < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(delegate.requests, count)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testPrimaryCloseRequestsShutdownEvenWhenAuxiliaryWindowRemains() async throws {
        let delegate = ShutdownDelegateSpy(cli: try VPhoneBootCLI.parse(["--config", "/tmp/unopened-window-test.plist"]))
        let controller = delegate.makeWindowController()
        let primary = window(), auxiliary = window()
        defer { primary.delegate = nil; primary.close(); auxiliary.close() }
        primary.delegate = controller
        XCTAssertEqual(primary.delegate?.windowShouldClose?(primary), false)
        await waitForRequests(1, from: delegate)
        XCTAssertNil(auxiliary.delegate)
        XCTAssertEqual(primary.delegate?.windowShouldClose?(primary), false)
        await waitForRequests(2, from: delegate)
    }

    func testCloseWithoutShutdownOwnerKeepsDefaultWindowBehavior() {
        let controller = VPhoneWindowController()
        let primary = window()
        defer { primary.delegate = nil; primary.close() }
        primary.delegate = controller
        XCTAssertEqual(primary.delegate?.windowShouldClose?(primary), true)
    }

    func testPrimaryCloseDefersShutdownUntilActiveGuestWriterCompletes() async throws {
        let delegate = ShutdownDelegateSpy(cli: try VPhoneBootCLI.parse(["--config", "/tmp/unopened-writer-test.plist"]))
        let writes = delegate.guestWrites
        var release: CheckedContinuation<Void, Never>?
        let active = Task { try await writes.run { await withCheckedContinuation { release = $0 } } }
        defer { release?.resume() }
        while release == nil { await Task.yield() }
        var queuedEntered = false, queuedWrote = false
        let queued = Task {
            queuedEntered = true
            try await writes.run { queuedWrote = true }
        }
        while !queuedEntered { await Task.yield() }
        let controller = delegate.makeWindowController(), primary = window()
        defer { primary.delegate = nil; primary.close() }
        primary.delegate = controller
        XCTAssertEqual(primary.delegate?.windowShouldClose?(primary), false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(primary.delegate?.windowShouldClose?(primary), false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(delegate.requests, 0)
        XCTAssertFalse(queuedWrote)
        release?.resume()
        release = nil
        try await active.value
        do { try await queued.value; XCTFail("queued writer ran after close requested shutdown") } catch {}
        await waitForRequests(1, from: delegate)
        XCTAssertFalse(queuedWrote)
        do { try await writes.run {}; XCTFail("window close left guest writes open") } catch {}
    }
}
