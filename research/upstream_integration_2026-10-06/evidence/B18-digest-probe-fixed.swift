import Foundation
import CryptoKit
let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
var hash = SHA256()
while try autoreleasepool(invoking: { () throws -> Bool in
    guard let data = try input.read(upToCount: 1 << 20), !data.isEmpty else { return false }
    hash.update(data: data)
    return true
}) {}
print(hash.finalize().map { String(format: "%02x", $0) }.joined())
