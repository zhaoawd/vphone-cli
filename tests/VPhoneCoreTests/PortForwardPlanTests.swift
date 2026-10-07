import Foundation
import Testing
@testable import VPhoneCore

struct PortForwardPlanTests {
    @Test func omittedAddressIsLoopbackAndProtocolsRemainDistinct() throws {
        let tcp = try VPhonePortForwardPlan.parse("8022:22")
        let udp = try VPhonePortForwardPlan.parse("udp:8022:22")
        #expect(tcp.hostAddress == nil)
        #expect(tcp.listenAddress == "127.0.0.1")
        #expect(tcp.transport == .tcp)
        #expect(udp.transport == .udp)
        #expect(try VPhonePortForwardPlan.validate([tcp, udp], mode: "nat") == [tcp, udp])
        #expect(try VPhonePortForwardPlan.validate([tcp], mode: "tunnel") == [tcp])
    }

    @Test func wildcardOverlapAndMalformedInputsAreRefusedBeforeAnyListenerExists() throws {
        let loopback = try VPhonePortForwardPlan.parse("tcp:8022:22")
        let wildcard = try VPhonePortForwardPlan.parse("tcp:0.0.0.0:8022:80")
        #expect(throws: VPhonePortForwardPlan.Error.self) { try VPhonePortForwardPlan.validate([loopback, wildcard], mode: "nat") }
        #expect(throws: VPhonePortForwardPlan.Error.self) { try VPhonePortForwardPlan.validate([loopback, loopback], mode: "nat") }
        for mode in ["bridged", "none", "hostOnly"] {
            #expect(throws: VPhonePortForwardPlan.Error.self) { try VPhonePortForwardPlan.validate([loopback], mode: mode) }
        }
        for input in ["0:22", "65536:22", "8022:-1", "tcp::22", "tcp:localhost:22:22", "tcp:999.0.0.1:22:22", "tcp:127.0.0.1:1:2:3", "tcp:1.2.3.4: 22:22", "tcp:1.2.3.4:22:22\n", "tcp:１.2.3.4:22:22"] {
            #expect(throws: VPhonePortForwardPlan.Error.self) { try VPhonePortForwardPlan.parse(input) }
        }
    }

    @Test func serializedProtocolFieldMatchesUpstreamAndDecodedInvalidPortsAreRejected() throws {
        let bytes = Data(#"{"protocol":"udp","hostPort":8022,"guestPort":22}"#.utf8)
        let value = try JSONDecoder().decode(VPhonePortForwardPlan.self, from: bytes)
        #expect(value.transport == .udp)
        #expect(value.listenAddress == "127.0.0.1")
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(fields["protocol"] as? String == "udp")
        #expect(fields["transport"] == nil)
        let invalid = try JSONDecoder().decode(VPhonePortForwardPlan.self, from: Data(#"{"protocol":"tcp","hostPort":0,"guestPort":22}"#.utf8))
        #expect(throws: VPhonePortForwardPlan.Error.self) { try VPhonePortForwardPlan.validate([invalid], mode: "nat") }
    }

    @Test func explicitAddressesAndCanonicalDescriptionsAreRoundTrippable() throws {
        let plan = try VPhonePortForwardPlan.parse("UDP:127.0.0.2:1234:4321")
        #expect(try VPhonePortForwardPlan.parse("udp:127.000.000.002:1234:4321") == plan)
        #expect(plan.description == "udp:127.0.0.2:1234:4321")
        #expect(try VPhonePortForwardPlan.parse(plan.description) == plan)
        let other = try VPhonePortForwardPlan.parse("udp:127.0.0.3:1234:4321")
        #expect(try VPhonePortForwardPlan.validate([plan, other], mode: "tunnel") == [plan, other])
    }
}
