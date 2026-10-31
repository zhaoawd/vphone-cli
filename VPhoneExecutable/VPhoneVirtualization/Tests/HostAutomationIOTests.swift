import Darwin
import Foundation

@main
struct HostAutomationIOTests {
    static func pair() -> [Int32] {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var value: Int32 = 1
        for fd in fds { precondition(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, 4) == 0) }
        return fds
    }

    static func main() {
        var count = 0
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            let data = Data("{\"t\":\"中文\"}\n".utf8)
            DispatchQueue.global().async {
                for byte in data { var byte = byte; _ = Darwin.write(fds[1], &byte, 1) }
            }
            precondition(VPhoneHostAutomationIO.readCommand(from: fds[0])?.line == "{\"t\":\"中文\"}")
            count += 1
        }
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            let data = Data("{\"t\":\"tap\"}".utf8)
            _ = data.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
            shutdown(fds[1], SHUT_WR)
            precondition(VPhoneHostAutomationIO.readCommand(from: fds[0]) == nil)
            count += 1
        }
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            DispatchQueue.global().async {
                let data = Data(repeating: 0x61, count: (1 << 20) + 1) + [0x0A]
                _ = VPhoneHostAutomationIO.write(data, to: fds[1], timeout: 1)
                shutdown(fds[1], SHUT_WR)
            }
            // The writer itself substitutes a bounded JSON error for an
            // oversized response rather than transmitting invalid JSON.
            let line = VPhoneHostAutomationIO.readCommand(from: fds[0])!.line
            precondition(line.contains("response exceeds"))
            count += 1
        }
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            let writer = DispatchGroup()
            writer.enter()
            DispatchQueue.global().async {
                defer { writer.leave() }
                let data = Data(repeating: 0x61, count: (1 << 20) + 1) + [0x0A]
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(fds[1], raw.baseAddress! + offset, raw.count - offset)
                        guard written > 0 else { return }
                        offset += written
                    }
                }
            }
            precondition(VPhoneHostAutomationIO.readCommand(from: fds[0], timeout: 1) == nil)
            shutdown(fds[0], SHUT_RDWR)
            precondition(writer.wait(timeout: .now() + 1) == .success)
            count += 1
        }
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            let start = ProcessInfo.processInfo.systemUptime
            precondition(VPhoneHostAutomationIO.readCommand(from: fds[0], timeout: 0.05) == nil)
            precondition(ProcessInfo.processInfo.systemUptime - start < 0.5)
            count += 1
        }
        do {
            let fds = pair(); defer { fds.forEach { close($0) } }
            var size: Int32 = 4096
            precondition(setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, 4) == 0)
            let start = ProcessInfo.processInfo.systemUptime
            precondition(!VPhoneHostAutomationIO.write(Data(repeating: 0x61, count: 1 << 20), to: fds[0], timeout: 0.05))
            precondition(ProcessInfo.processInfo.systemUptime - start < 0.5)
            count += 1
        }
        print("\(count) host I/O tests passed")
    }
}
