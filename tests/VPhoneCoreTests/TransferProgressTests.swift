import Foundation
import Testing
@testable import VPhoneCore

struct TransferProgressTests {
    @Test func regularFileChannelToleratesReaderRemovalAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = try VPhoneTransferProgressChannel(parent: root, direction: .importArchive)
        let reporter = try #require(VPhoneTransferProgressReporter(direction: .importArchive, environment: channel.environment))
        #expect(VPhoneTransferProgressReporter(direction: .importArchive, environment: channel.environment) == nil)
        reporter.update(bytes: 5, total: 10)
        #expect(channel.read()?.fraction == 0.5)
        reporter.update(bytes: 10, total: 10, completed: true)
        #expect(channel.read()?.completed == true)
        channel.close()
        // The reporter still owns a regular-file descriptor; no reader is needed.
        reporter.update(bytes: 11, total: nil, completed: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        withExtendedLifetime(reporter) {}
    }

    @Test func decoderRejectsMalformedFutureNegativeAndOverTotalRecords() throws {
        for json in ["{}", "{", "{\"version\":2,\"direction\":\"importArchive\",\"completed\":false,\"bytes\":1}",
                     "{\"version\":1,\"direction\":\"importArchive\",\"completed\":false,\"bytes\":-1}",
                     "{\"version\":1,\"direction\":\"importArchive\",\"completed\":false,\"bytes\":2,\"total\":1}"] {
            #expect(VPhoneTransferProgress.decode(Data(json.utf8)) == nil)
        }
        let unknown = VPhoneTransferProgress(direction: .exportArchive, bytes: 100, total: nil)
        #expect(try VPhoneTransferProgress.decode(JSONEncoder().encode(unknown)) == unknown)
        #expect(unknown.fraction == nil)
    }

    @Test func readerIgnoresOtherDirectionRegressionsAndIncompleteLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let channel = try VPhoneTransferProgressChannel(parent: root, direction: .importArchive)
        var data = Data()
        for value in [VPhoneTransferProgress(direction: .exportArchive, bytes: 9, total: nil),
                      .init(direction: .importArchive, bytes: 5, total: 10),
                      .init(direction: .importArchive, bytes: 3, total: 10)] {
            data.append(try JSONEncoder().encode(value)); data.append(10)
        }
        data.append(try JSONEncoder().encode(VPhoneTransferProgress(direction: .importArchive, bytes: 10, total: 10)))
        try data.write(to: channel.file)
        #expect(channel.read()?.bytes == 5)
    }

    @Test func reporterRefusesAnExistingSymlinkAndKeepsTargetBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        #expect(VPhoneTransferProgressReporter(direction: .exportArchive,
            environment: [VPhoneTransferProgressChannel.environmentKey: link.path]) == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }
}
