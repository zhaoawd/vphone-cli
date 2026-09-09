import Foundation
import Testing
@testable import vphone_cli

struct PatchComponentResultTests {
    private func workspace(_ body: (URL, URL, URL, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.bin")
        let output = dir.appendingPathComponent("output.bin")
        let report = dir.appendingPathComponent("report.json")
        try Data(repeating: 0, count: 0x400).write(to: input)
        try body(dir, input, output, report)
    }

    @Test func necessaryFailureWritesReportButPreservesOutput() throws {
        try workspace { _, input, output, report in
            let sentinel = Data("existing output".utf8)
            try sentinel.write(to: output)
            var command = try PatchComponentCLI.parse(["--component", "kernel-base",
                "--input", input.path, "--output", output.path, "--report-out", report.path, "--quiet"])
            #expect(throws: (any Error).self) { try command.run() }
            #expect(try Data(contentsOf: output) == sentinel)
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
            let components = try #require(json["components"] as? [[String: Any]])
            #expect(components.first?["coverage"] as? String == "structured")
            let results = try #require(components.first?["results"] as? [[String: Any]])
            #expect(results.contains { $0["outcome"] as? String == "failed" })
        }
    }

    @Test func methodAblationIsAcceptedAndDryRunWritesNoPayload() throws {
        try workspace { dir, input, output, _ in
            let report = dir.appendingPathComponent("new-report-directory/report.json")
            var command = try PatchComponentCLI.parse(["--component", "txm",
                "--input", input.path, "--output", output.path, "--report-out", report.path,
                "--ablate", "txm.TXMPatcher.patchTrustcacheBypass", "--quiet"])
            try command.run()
            #expect(!FileManager.default.fileExists(atPath: output.path))
            let text = try String(contentsOf: report, encoding: .utf8)
            #expect(text.contains("ablated"))
            #expect(text.contains("structured"))
        }
    }
}
