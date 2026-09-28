import Foundation
import Testing
@testable import VPhoneDaemonWire

struct APIRequestTests {
    @Test func preservesMethodParametersAndIdentifier() throws {
        let request = try APIRequest.decode(Data(#"{"method":"device.info","params":{"verbose":true,"nested":[1,"x"]},"id":"r-42"}"#.utf8))
        #expect(request.method == "device.info")
        #expect(request.id as? String == "r-42")
        #expect(request.params["verbose"] as? Bool == true)
        #expect((request.params["nested"] as? [Any])?.count == 2)
    }

    @Test func omittedParametersAndIdentifierRemainOptional() throws {
        let request = try APIRequest.decode(Data(#"{"method":"health"}"#.utf8))
        #expect(request.params.isEmpty)
        #expect(request.id == nil)
    }

    @Test(arguments: ["[]", "null", "{}", #"{"method":1}"#, #"{"method":""}"#,
                      #"{"method":"health","params":[]}"#, #"{"method":"health","params":null}"#,
                      #"{"method":"health","id":[]}"#, #"{"method":"health","id":{}}"#,
                      #"{"method":"health","id":null}"#, "not-json"])
    func rejectsInvalidRequestShapes(input: String) {
        #expect(throws: (any Error).self) { try APIRequest.decode(Data(input.utf8)) }
    }

    @Test func methodLengthBoundary() throws {
        func encoded(_ count: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["method": String(repeating: "x", count: count)])
        }
        #expect(try APIRequest.decode(encoded(128)).method.count == 128)
        #expect(throws: APIRequestDecodingError.self) { try APIRequest.decode(encoded(129)) }
    }

    @Test func preservesNumericIDWithoutStringConversion() throws {
        let request = try APIRequest.decode(Data(#"{"method":"health","id":12345}"#.utf8))
        #expect((request.id as? NSNumber)?.intValue == 12345)
        #expect(!(request.id is String))
    }

    @Test func reportsStableInvalidEnvelopeMessage() {
        do {
            _ = try APIRequest.decode(Data(#"{"params":{}}"#.utf8))
            Issue.record("Expected missing method to fail")
        } catch {
            #expect(String(describing: error) == "Expected {method, params?, id?}")
        }
    }
}
