import Foundation

@main struct Benchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/vphone-b13-log-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = String(repeating: "console payload ", count: 8), count = 100000
        var results: [[String: Any]] = []
        for batch in [false, true] {
            let file = root.appendingPathComponent(batch ? "batch.log" : "sync.log")
            let started = Date()
            if batch {
                let writer = try VPhoneLogWriter(url: file)
                await Task.detached { for i in 0..<count { writer.write("\(i) \(line)") } }.value
                try await writer.finish()
            } else {
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                try await Task.detached {
                    for i in 0..<count { try handle.write(contentsOf: Data("\(i) \(line)\n".utf8)) }
                    try handle.synchronize(); try handle.close()
                }.value
            }
            let elapsed = Date().timeIntervalSince(started), data = try Data(contentsOf: file)
            guard data.filter({ $0 == 10 }).count == count, String(decoding: data.suffix(150), as: UTF8.self).contains("99999 ") else { throw NSError(domain: "Benchmark", code: 1) }
            results.append(["implementation":batch ? "VPhoneLogWriter batch" : "per-line FileHandle.write baseline", "records":count, "bytes":data.count, "seconds":elapsed, "records_per_second":Double(count)/elapsed])
        }
        let json = try JSONSerialization.data(withJSONObject: ["results":results,"UI_responsiveness_measured":false,"guest_console_measured":false], options: [.prettyPrinted,.sortedKeys])
        try json.write(to: URL(fileURLWithPath: "/private/tmp/vphone-b13-log-benchmark.json"),options:.withoutOverwriting)
        print(String(decoding:json,as:UTF8.self))
    }
}
