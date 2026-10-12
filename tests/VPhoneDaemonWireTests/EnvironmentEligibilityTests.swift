import CryptoKit
import Foundation
import Testing
@testable import VPhoneDaemonWire

struct EnvironmentEligibilityTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("env-mode-" + UUID().uuidString)
        let names = EnvironmentTransactionTests.names
        init() throws {
            for path in ["sbin/launchd", "usr/bin/vphoned-api"] + names.map({ "usr/lib/" + $0 }) {
                try write(path, Self.image())
            }
            try write("System/Library/xpc/launchd.plist.bak", Data("cfw".utf8))
            try plist("System/Library/xpc/launchd.plist", ["LaunchDaemons": ["/System/Library/LaunchDaemons/vphoned-api.plist": true]])
            try plist("System/Library/LaunchDaemons/vphoned-api.plist", ["Label": "com.vphone.vphoned.api", "ProgramArguments": ["/usr/bin/vphoned-api"], "EnvironmentVariables": ["VPHONED_VCAM": "off"]])
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("vh").path, withDestinationPath: "/usr/lib/launchdhook-vphone.dylib")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func plist(_ path: String, _ value: [String: Any]) throws {
            try write(path, PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
        }
        static func image(load: String = "/vh", signed: Bool = true) -> Data {
            var data = Data()
            func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
            [UInt32(0xfeedfacf), 0x100000c, 0, 2, 2, 48, 0, 0].forEach(u32)
            [UInt32(0xc), 32, 24, 0, 0, 0].forEach(u32)
            var name = Data(load.utf8); name.append(contentsOf: [UInt8](repeating: 0, count: 8 - name.count)); data.append(name)
            [UInt32(signed ? 0x1d : 0), 16, 80, 12].forEach(u32)
            data.append(contentsOf: [0xfa,0xde,0x0c,0xc0,0,0,0,12,0,0,0,0])
            return data
        }
        func inspect() -> [String: Any] {
            EnvironmentEligibility(root: root, libraries: names).inspect(runningDaemonSHA256: EnvironmentTransactionTests.digestImage(Self.image()))
        }
    }

    @Test func completeActualInstallationQualifiesExistingLibrariesOnly() throws {
        let f = try Fixture()
        #expect(f.inspect()["eligible"] as? Bool == true)
        #expect(f.inspect()["mode"] as? String == "regular-v2")
    }

    @Test(arguments: ["loader", "signature", "mixed", "missing", "symlink", "job", "key", "daemon", "pending", "marker"])
    func actualInspectionFailsClosed(_ mutation: String) throws {
        let f = try Fixture()
        switch mutation {
        case "loader": try f.write("sbin/launchd", Fixture.image(load: "/x"))
        case "signature": try f.write("sbin/launchd", Fixture.image(signed: false))
        case "mixed": try f.write("b", Data())
        case "missing": try FileManager.default.removeItem(at: f.root.appendingPathComponent("usr/lib/libcamfix.dylib"))
        case "symlink":
            let path = f.root.appendingPathComponent("usr/lib/libcamfix.dylib")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.root.appendingPathComponent("usr/lib/libvlocation.dylib"))
        case "job": try f.plist("System/Library/LaunchDaemons/vphoned-api.plist", ["ProgramArguments": ["/usr/bin/vphoned"]])
        case "key": try f.plist("System/Library/xpc/launchd.plist", ["LaunchDaemons": [:]])
        case "daemon": try f.write("usr/bin/vphoned-api", Data("wrong".utf8))
        case "pending": try f.write("var/root/Library/Caches/vphoned.api-v2.pending", Data())
        default: try f.write("var/root/Library/Caches/vphoned.api-v2", Data("old-marker".utf8))
        }
        #expect(f.inspect()["eligible"] as? Bool == false)
    }
}
extension EnvironmentTransactionTests {
    static func digestImage(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
