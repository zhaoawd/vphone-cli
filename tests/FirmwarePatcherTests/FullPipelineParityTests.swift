import Foundation
import XCTest
@testable import FirmwarePatcher

/// Runs production component selection without writing firmware to disk.
final class FullPipelineParityTests: XCTestCase {
    func testNonLessLegacyAndStructuredPayloadsMatch() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VPHONE_TEST_PIPELINE_VM"] else {
            throw XCTSkip("Set VPHONE_TEST_PIPELINE_VM to a fresh staged firmware VM directory")
        }
        let variantName = env["VPHONE_TEST_PIPELINE_VARIANT"] ?? "regular"
        let variant = try XCTUnwrap(FirmwarePipeline.Variant(rawValue: variantName))
        guard variant != .less else {
            throw XCTSkip("Filesystem side effects require the separate less acceptance test")
        }
        let loader = MemoryPipelineLoader()
        let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: path), variant: variant,
            verbose: false, forceExcGuard: env["VPHONE_TEST_PIPELINE_FORCE_EXC_GUARD"] == "1",
            enableFrida: env["VPHONE_TEST_PIPELINE_FRIDA"] == "1", loader: loader)
        let report = try pipeline.patchAllStructured()
        XCTAssertTrue(report.failedRequired.isEmpty)
        XCTAssertFalse(report.isAblationRun)
        XCTAssertTrue(report.components.allSatisfy { $0.coverage == .structured })
        XCTAssertTrue(report.components.flatMap(\.results).allSatisfy { $0.outcome != .failed })
        let restore = try pipeline.findRestoreDirectory()
        let components = pipeline.buildComponentList()
        XCTAssertEqual(loader.saves.count, components.count)
        for component in components {
            let base = component.inRestoreDir ? restore : pipeline.vmDirectory
            let url = try pipeline.findFile(in: base, patterns: component.searchPatterns, label: component.name)
            let original = try XCTUnwrap(loader.originalPayloads[url])
            // patchAllStructured prepared the actual manifest-derived gates above;
            // its production factories now carry those same options into legacy execution.
            let (legacyData, legacyRecords) = try pipeline.patchData(original,
                componentName: component.name, patcherFactories: component.patcherFactories)
            let saved = try XCTUnwrap(loader.outputs[url])
            XCTAssertEqual(legacyData, saved, "Complete serialized payload: \(component.name)")
            if let outputPath = env["VPHONE_TEST_PIPELINE_OUTPUT_VM"] {
                let prefix = pipeline.vmDirectory.standardizedFileURL.path + "/"
                let inputPath = url.standardizedFileURL.path
                XCTAssertTrue(inputPath.hasPrefix(prefix))
                let relative = String(inputPath.dropFirst(prefix.count))
                let baselineURL = URL(fileURLWithPath: outputPath).appendingPathComponent(relative)
                let baseline = try FirmwarePipeline.ContainerFirmwareLoader().load(from: baselineURL)
                XCTAssertEqual(baseline, saved, "Pre-merge CLI complete payload: \(component.name)")
                print("C3 pre-merge output parity variant=\(variantName) component=\(component.name) bytes=\(baseline.count)")
            }
            let structuredRecords = report.components.filter { $0.component == component.name }.flatMap(\.records)
            XCTAssertEqual(legacyRecords, structuredRecords, "Complete records: \(component.name)")
            if !component.patcherFactories.isEmpty {
                XCTAssertFalse(legacyRecords.isEmpty, "Non-empty evidence: \(component.name)")
            }
            print("C3 full pipeline parity variant=\(variantName) component=\(component.name) records=\(legacyRecords.count) bytes=\(legacyData.count)")
        }
        // Check exact input containers, not only decoded payloads, after both paths.
        for (url, bytes) in loader.originalContainers {
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Input changed: \(url.path)")
        }
    }
}

private final class MemoryPipelineLoader: FirmwarePipeline.FirmwareLoader {
    var originalContainers: [URL: Data] = [:]
    var originalPayloads: [URL: Data] = [:]
    var outputs: [URL: Data] = [:]
    var saves: [URL] = []

    func load(from url: URL) throws -> Data {
        let key = logicalURL(url)
        if let data = outputs[key] { return data }
        if let data = originalPayloads[key] { return data }
        let bytes = try Data(contentsOf: url)
        let payload = try FirmwarePipeline.ContainerFirmwareLoader().load(from: url)
        originalContainers[key] = bytes
        originalPayloads[key] = payload
        return payload
    }

    func save(_ data: Data, to url: URL) throws {
        let key = logicalURL(url)
        outputs[key] = data
        saves.append(key)
    }

    private func logicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path.replacingOccurrences(of: "/.firmware-transaction/stage/", with: "/"))
    }
}
