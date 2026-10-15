import Darwin
import Foundation

// Run only in a test-owned child. Restoring these handlers must make the
// final signal exit 74 instead of entering another DispatchSource callback.
signal(SIGINT) { _ in _exit(74) }
signal(SIGTERM) { _ in _exit(74) }

@MainActor
final class Fixture {
    var signals: VPhoneShutdownSignals?
    var count = 0

    init() {
        signals = VPhoneShutdownSignals { [weak self] number in
            self?.received(number)
        }
    }

    func received(_ number: Int32) {
        guard Thread.isMainThread else { _exit(92) }
        count += 1
        FileHandle.standardOutput.write(Data("received \(number)\n".utf8))
        if count == 2 {
            signals = nil
            FileHandle.standardOutput.write(Data("restored\n".utf8))
            kill(getpid(), number)
        }
    }
}

let fixture = Fixture()
FileHandle.standardOutput.write(Data("ready\n".utf8))
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { _exit(99) }
RunLoop.main.run()
withExtendedLifetime(fixture) {}
