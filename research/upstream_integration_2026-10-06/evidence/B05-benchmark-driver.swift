import Foundation
let source = Data(String(repeating: "\u{1b}[32mserial 中文 line 123\u{1b}[0m\r\n", count: 100000).utf8)
for _ in 0..<3 {
    var splitter = VPhoneLaunchpadLineSplitter()
    var count = 0, bytes = 0
    let start = ContinuousClock.now
    for offset in stride(from: 0, to: source.count, by: 1024 * 1024) {
        splitter.feed(source.subdata(in: offset..<min(source.count, offset + 1024 * 1024))) { count += 1; bytes += $0.utf8.count }
    }
    splitter.flush { count += 1; bytes += $0.utf8.count }
    print("input_bytes=\(source.count) output_lines=\(count) output_bytes=\(bytes) elapsed=\(start.duration(to: .now))")
}
