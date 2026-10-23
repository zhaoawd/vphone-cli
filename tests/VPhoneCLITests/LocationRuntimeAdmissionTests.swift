import Foundation
import Darwin
import XCTest
import VPhoneCore
@testable import vphone_cli

final class LocationRuntimeAdmissionTests: XCTestCase {
    func testCapabilitiesUsesActualWireDispatcherWithoutGuest() async throws {
        let response = try await Task.detached { () throws -> Data in
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw NSError(domain: "socketpair", code: 1) }
            let client = fds[0], server = fds[1]
            defer { close(client) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async { VPhoneHostControl.handleClient(server, controller: nil) }
            let request = Data("{\"t\":\"capabilities\"}\n".utf8)
            _ = request.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &bytes, bytes.count)
            guard count > 0 else { throw NSError(domain: "capabilities_read", code: Int(count)) }
            return Data(bytes.prefix(count))
        }.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true, String(decoding: response, as: UTF8.self))
        XCTAssertEqual(object["guest_connected"] as? Bool, false)
        XCTAssertEqual(object["guest_capabilities"] as? [String], [])
        let commands = try XCTUnwrap(object["commands"] as? [String: Bool])
        XCTAssertEqual(commands["location_source_set"], false)
    }

    func testOwnedLocationCapabilitiesRequireConnectedGuestAndProvider() throws {
        for connected in [false, true] {
            for provider in [false, true] {
                for owned in [false, true] {
                    let caps = owned ? ["location", "location_owned", "shell"] : ["location", "shell"]
                    let result = VPhoneHostControl.capabilitySnapshot(connected: connected,
                        guestCapabilities: caps, hasLocationProvider: provider, screenAvailable: false)
                    let commands = try XCTUnwrap(result["commands"] as? [String: Bool])
                    XCTAssertEqual(result["guest_capabilities"] as? [String], connected ? caps : [])
                    for command in ["location_source_set", "location_stream_start", "location_stream_push",
                                    "location_source_control", "location_source_stop"] {
                        XCTAssertEqual(commands[command], connected && provider && owned)
                    }
                    XCTAssertEqual(commands["location_source_status"], provider)
                    XCTAssertEqual(commands["shell"], connected)
                }
            }
        }
    }

    func testDefaultGuestBinaryUsesExecutableResourcesNotVMCWD() throws {
        let cli = try VPhoneBootCLI.parse(["--config", "/unrelated/vm/config.plist"])
        XCTAssertEqual(cli.vphonedBin, VPhoneResources.resolve().vphoned.path)
        let explicit = try VPhoneBootCLI.parse(["--config", "/unrelated/vm/config.plist", "--vphoned-bin", "/specific/vphoned"])
        XCTAssertEqual(explicit.vphonedBin, "/specific/vphoned")
    }
}
