import Darwin
import Foundation

@main
enum HTTPReadTests {
    static func main() throws {
        typealias Failure = VPhoneGuestControl.ControlError
        let timeout = Failure.protocolError("HTTP response timed out")
        var failures = 0
        func expect(_ name: String, _ expected: Failure?, _ body: () throws -> Void) {
            let actual: Failure?
            do {
                try body()
                actual = nil
            } catch let error as Failure {
                actual = error
            } catch {
                print("FAIL: \(name): \(error)")
                failures += 1
                return
            }
            if actual != expected {
                print("FAIL: \(name): expected \(String(describing: expected)), got \(String(describing: actual))")
                failures += 1
            }
        }

        var sockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let reader = HTTPReader(deadline: .now.advanced(by: .seconds(2)))
        var data = Data()
        expect("socket read timeout while the peer is still open", timeout) {
            try reader.readMore(sockets[0], into: &data)
        }
        expect("overall deadline expires", timeout) {
            try HTTPReader(deadline: .now).readMore(sockets[0], into: &data)
        }
        expect("successful read", nil) {
            var byte: UInt8 = 42
            precondition(write(sockets[1], &byte, 1) == 1)
            try reader.readMore(sockets[0], into: &data)
            precondition(data == Data([42]))
        }
        precondition(shutdown(sockets[1], SHUT_WR) == 0)
        expect("peer EOF remains a disconnect", .notConnected) {
            try reader.readMore(sockets[0], into: &data)
        }
        print("HTTP read: \(4 - failures)/4 passed")
        if failures != 0 { exit(1) }
    }
}
