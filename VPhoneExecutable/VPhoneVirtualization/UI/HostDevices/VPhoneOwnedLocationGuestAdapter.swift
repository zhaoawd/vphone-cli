import Foundation
import VPhoneCoreKit

@MainActor
final class VPhoneOwnedLocationGuestAdapter: VPhoneSystemLocationGuestAdapter {
    private weak var control: VPhoneGuestControl?
    init(control: VPhoneGuestControl) { self.control = control }

    func requireOwnedLocationCapability() throws {
        guard let control, control.isConnected, control.guestCapabilities.contains("location_owned") else {
            throw VPhoneSystemLocationError(code: "location_guest_unavailable", message: "guest has no owned location capability")
        }
    }
    func activate(generation: String) async throws {
        _ = try await call("location.source.begin", ["generation": generation])
    }
    func deliver(_ fix: VPhoneSystemLocationFix, generation: String, deliverySequence: Int) async throws {
        var params: [String: Any] = ["generation": generation, "delivery_sequence": deliverySequence,
            "latitude": fix.latitude, "longitude": fix.longitude, "altitude": fix.altitude,
            "horizontal_accuracy": fix.horizontalAccuracy, "vertical_accuracy": fix.verticalAccuracy, "timestamp": fix.timestamp]
        if fix.speed >= 0 { params["speed"] = fix.speed }
        if fix.course >= 0 { params["course"] = fix.course }
        let result = try await call("location.source.deliver", params)
        guard result["generation"] as? String == generation, result["delivery_sequence"] as? Int == deliverySequence else {
            throw VPhoneSystemLocationError(code: "location_protocol_error", message: "guest delivery identity mismatch")
        }
    }
    func clear(generation: String?) async throws {
        if let generation { _ = try await call("location.source.clear", ["generation": generation]) }
        else { _ = try await call("location.clear", [:], requiresOwned: false) }
    }
    private func call(_ method: String, _ params: [String: Any], requiresOwned: Bool = true) async throws -> [String: Any] {
        if requiresOwned { try requireOwnedLocationCapability() }
        guard let control, control.isConnected, control.guestCapabilities.contains("location") else {
            throw VPhoneSystemLocationError(code: "location_guest_unavailable", message: "guest location unavailable")
        }
        do { return try await control.rpcAfterQueuedInput(method, params: params) }
        catch let failure as VPhoneGuestControl.GuestRPCFailure {
            throw VPhoneSystemLocationError(code: failure.body["code"] as? String ?? "location_delivery_rejected",
                message: failure.message, definitiveGuestRejection: true)
        } catch {
            throw VPhoneSystemLocationError(code: "location_delivery_timeout", message: String(describing: error))
        }
    }
}
