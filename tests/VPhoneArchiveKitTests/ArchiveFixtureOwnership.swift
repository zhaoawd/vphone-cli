import Darwin
import Foundation
import Testing
@testable import VPhoneArchiveKit

/// Strict ustar uses six octal digits for each numeric owner ID. Files made
/// by directory-service accounts can exceed that range. In that environment
/// verify refusal and staging cleanup; do not silently replace their owners.
enum ArchiveFixtureOwnership {
    static func expectUSTARRefusalIfNeeded(
        format: VPhoneArchiveFormat, source: URL, archive: URL
    ) throws -> Bool {
        var info = stat()
        try #require(lstat(source.path, &info) == 0)
        guard format == .ustar, info.st_uid > 0o777777 || info.st_gid > 0o777777 else { return false }
        let error = #expect(throws: VPhoneArchiveError.self) {
            try VPhoneArchiveWriter.create(archive: archive, from: source, format: format)
        }
        if case let .writeFailed(_, reason)? = error {
            #expect(reason == "Numeric user ID too large" || reason == "Numeric group ID too large")
        } else {
            Issue.record("expected an unrepresentable ustar owner error, got \(String(describing: error))")
        }
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.hasPrefix(".vphone-archive-") })
        return true
    }
}
