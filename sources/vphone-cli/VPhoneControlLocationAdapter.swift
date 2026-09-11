import Foundation
import VPhoneCore

@MainActor
final class VPhoneControlLocationGuestAdapter: VPhoneSystemLocationGuestAdapter {
    private weak var control: VPhoneControl?

    init(control: VPhoneControl) {
        self.control = control
    }

    func requireOwnedLocationCapability() throws {
        try requireLocationCapability(owned: true)
    }

    func activate(generation: String) async throws {
        let response = try await request([
            "t": "location_source_begin",
            "generation": generation,
        ], owned: true)
        try Self.requireOK(response, fallback: "guest rejected location source")
    }

    func deliver(
        _ fix: VPhoneSystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        let response = try await request([
            "t": "location",
            "generation": generation,
            "delivery_sequence": deliverySequence,
            "lat": fix.latitude, "lon": fix.longitude, "alt": fix.altitude,
            "hacc": fix.horizontalAccuracy, "vacc": fix.verticalAccuracy,
            "speed": fix.speed, "course": fix.course, "ts": fix.timestamp,
        ], owned: true)
        try Self.requireOK(response, fallback: "guest rejected location")
    }

    func clear(generation: String?) async throws {
        var payload: [String: Any] = ["t": "location_stop"]
        if let generation { payload["generation"] = generation }
        let response = try await request(payload, owned: generation != nil)
        try Self.requireOK(response, fallback: "guest rejected location_stop")
    }

    private func request(
        _ payload: [String: Any],
        owned: Bool
    ) async throws -> [String: Any] {
        try requireLocationCapability(owned: owned)
        guard let control else {
            throw VPhoneSystemLocationError(
                code: "location_guest_unavailable", message: "guest not connected")
        }
        let response: [String: Any]
        do {
            (response, _) = try await control.sendRequest(payload)
        } catch let error as VPhoneControl.ControlError {
            throw Self.map(error)
        }
        return response
    }

    private func requireLocationCapability(owned: Bool) throws {
        guard let control, control.isConnected else {
            throw VPhoneSystemLocationError(
                code: "location_guest_unavailable", message: "guest not connected")
        }
        guard control.guestCaps.contains("location") else {
            throw VPhoneSystemLocationError(
                code: "location_guest_unavailable",
                message: "guest does not support location simulation")
        }
        if owned && !control.guestCaps.contains("location_owned") {
            throw VPhoneSystemLocationError(
                code: "location_guest_unavailable",
                message: "guest does not support owned location sources")
        }
    }

    private static func requireOK(
        _ response: [String: Any],
        fallback: String
    ) throws {
        guard (response["t"] as? String) == "ok" else {
            throw VPhoneSystemLocationError(
                code: response["code"] as? String ?? "location_delivery_rejected",
                message: response["msg"] as? String ?? fallback,
                definitiveGuestRejection: true)
        }
    }

    static func map(_ error: VPhoneControl.ControlError) -> VPhoneSystemLocationError {
        switch error {
        case .notConnected, .unsupportedCapability:
            VPhoneSystemLocationError(
                code: "location_guest_unavailable", message: error.description)
        case .requestTimedOut:
            VPhoneSystemLocationError(
                code: "location_delivery_timeout", message: error.description)
        case let .guestError(code, message):
            VPhoneSystemLocationError(
                code: code ?? "location_delivery_rejected",
                message: message,
                definitiveGuestRejection: true)
        default:
            VPhoneSystemLocationError(
                code: "location_delivery_rejected", message: error.description)
        }
    }
}
