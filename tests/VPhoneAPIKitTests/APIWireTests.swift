import Foundation
import Testing
@testable import VPhoneAPIKit

struct APIWireTests {
    @Test func validatesOptionalProcessIdentityAndAcceptsLegacyHealth() throws {
        var object: [String: Any] = ["status": "ok", "api_version": 1,
            "binary_hash": String(repeating: "a", count: 64), "capabilities": ["files"]]
        func decode() throws -> VPhoneAPIHealth {
            try VPhoneAPIHealth.decode(JSONSerialization.data(withJSONObject: object),
                requiredCapabilities: [], expectedBinaryHash: nil)
        }
        #expect(try decode().instanceID == nil)
        let id = UUID()
        object["instance_id"] = id.uuidString.lowercased()
        #expect(try decode().instanceID == id.uuidString)
        for invalid: Any in ["invalid", 42, NSNull()] {
            object["instance_id"] = invalid
            #expect(throws: (any Error).self) { try decode() }
        }
    }

    @Test func jsonRoundTripAndNullResult() throws {
        let value: VPhoneJSONValue = .object(["n": .null, "b": .bool(true), "a": .array([.number(3), .string("中文")])])
        #expect(try JSONDecoder().decode(VPhoneJSONValue.self, from: JSONEncoder().encode(value)) == value)
        let message = try VPhoneAPIWire.message(Data(#"{"type":"response","id":"a","result":null}"#.utf8))
        guard case let .response(response) = message else { Issue.record("Expected response"); return }
        #expect(try VPhoneAPIWire.result(response) == .null)
    }

    @Test(arguments: [#"{"type":"response","id":"a"}"#,
                      #"{"type":"response","id":"a","result":{},"error":{"code":"x","message":"y"}}"#,
                      #"{"type":"response","id":null,"result":{}}"#,
                      #"{"type":"response","id":1,"result":{}}"#,
                      #"{"type":"event","event":"","data":{}}"#,
                      #"{"type":"event","event":"x"}"#, "[]", "null"])
    func rejectsMalformedEnvelopes(json: String) {
        #expect(throws: (any Error).self) { try VPhoneAPIWire.message(Data(json.utf8)) }
    }

    @Test func errorsPreserveCodeAndMessage() throws {
        let message = try VPhoneAPIWire.message(Data(#"{"type":"response","id":"a","error":{"code":"denied","message":"No access"}}"#.utf8))
        guard case let .response(response) = message else { Issue.record("Expected response"); return }
        do { _ = try VPhoneAPIWire.result(response); Issue.record("Expected error") }
        catch let error as VPhoneAPIError {
            #expect(error.code == "denied"); #expect(error.message == "No access")
        }
    }

    @Test func requestBoundaries() throws {
        _ = try VPhoneAPIWire.request(String(repeating: "m", count: 128), params: [:], id: "a")
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIWire.request("", params: [:], id: "a") }
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIWire.request(String(repeating: "m", count: 129), params: [:], id: "a") }
        let baseline = try VPhoneAPIWire.request("m", params: ["v": .string("")], id: "a").count
        let text = String(repeating: "x", count: VPhoneAPIWire.maximumRequestBytes - baseline)
        #expect(try VPhoneAPIWire.request("m", params: ["v": .string(text)], id: "a").count == VPhoneAPIWire.maximumRequestBytes)
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIWire.request("m", params: ["v": .string(text + "x")], id: "a") }
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIWire.message(Data(repeating: 32, count: VPhoneAPIWire.maximumResponseBytes + 1)) }
    }

    @Test func healthChecksVersionHashAndIndividualCapabilities() throws {
        let hash = String(repeating: "a", count: 64)
        func health(version: VPhoneJSONValue = .number(1), hash: String, caps: [VPhoneJSONValue] = [.string("files")]) throws -> Data {
            try JSONEncoder().encode(VPhoneJSONValue.object(["status": .string("ok"), "api_version": version,
                                                           "binary_hash": .string(hash), "capabilities": .array(caps)]))
        }
        let data = try health(hash: hash)
        let info = try VPhoneAPIHealth.decode(data, requiredCapabilities: ["files"], expectedBinaryHash: hash)
        #expect(info.capabilities == ["files"])
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIHealth.decode(data, requiredCapabilities: ["camera"], expectedBinaryHash: nil) }
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIHealth.decode(data, requiredCapabilities: [], expectedBinaryHash: String(repeating: "b", count: 64)) }
        for data in [try health(version: .number(2), hash: hash), try health(version: .bool(true), hash: hash),
                     try health(hash: "unknown"), try health(hash: hash, caps: [.number(1)])] {
            #expect(throws: VPhoneAPIError.self) { try VPhoneAPIHealth.decode(data, requiredCapabilities: [], expectedBinaryHash: nil) }
        }
    }

    @Test func endpointAndCredentialPolicy() throws {
        for url in ["file:///tmp/test", "http://user:secret@localhost", "http://localhost/?token=x", "http://localhost/#x"] {
            #expect(throws: VPhoneAPIError.self) { try VPhoneAPIClient(baseURL: URL(string: url)!) }
        }
        for timeout in [0, -1, .infinity, .nan, 131] {
            #expect(throws: VPhoneAPIError.self) { try VPhoneAPIClient(baseURL: URL(string: "http://localhost")!, timeout: timeout) }
        }
        #expect(throws: VPhoneAPIError.self) { try VPhoneAPIClient(baseURL: URL(string: "http://localhost")!, token: "bad\r\nvalue") }
        let client = try VPhoneAPIClient(baseURL: URL(string: "https://localhost/base")!, token: "1234567890abcdef")
        let request = client.webSocketRequest()
        #expect(request.url?.absoluteString == "wss://localhost/base/v1/events")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer 1234567890abcdef")
        #expect(request.url?.query == nil)
        #expect(!request.httpShouldHandleCookies)
    }
}
