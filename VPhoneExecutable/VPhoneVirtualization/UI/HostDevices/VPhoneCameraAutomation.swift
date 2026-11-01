import CoreFoundation
import Foundation

@MainActor
final class VPhoneCameraAutomation {
    private weak var camera: VPhoneCameraServer?
    private weak var control: VPhoneGuestControl?
    init(camera: VPhoneCameraServer, control: VPhoneGuestControl) { self.camera = camera; self.control = control }

    func handle(_ type: String, _ json: [String: Any]) async -> [String: Any] {
        guard let generation = json["generation"] as? String, !generation.isEmpty,
              generation.utf8.count < 80, !generation.utf8.contains(0) else {
            return ["ok": false, "error": "camera generation must contain 1...79 UTF-8 bytes without NUL"]
        }
        guard let camera else { return ["ok": false, "error": "camera server unavailable"] }
        if type == "camera_stop" {
            let status = camera.hostStatus(generation: generation)
            guard status["matches_requested"] as? Bool == true,
                  json["presentation_id"] == nil || json["presentation_id"] as? String == status["presentation_id"] as? String else {
                return ["ok": false, "error": "generation or presentation does not own camera source"]
            }
            let policy = json["policy"] as? String ?? "keep_last"
            if policy == "keep_last" {
                let stopped = camera.stop(generation: generation)
                return camera.hostStatus(generation: generation).merging(["ok": stopped, "stop_policy": policy, "guest_frame_cleared": false]) { _, new in new }
            }
            guard policy == "neutral" else { return ["ok": false, "error": "stop policy must be keep_last or neutral"] }
            let neutral = UUID().uuidString
            guard camera.presentNeutral(generation: neutral, fps: 8) else { return ["ok": false, "error": "neutral source unavailable"] }
            return await confirmation(generation: neutral)
        }
        if type == "camera_present" {
            guard let path = json["path"] as? String, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path),
                  let role = json["role"] as? String, ["neutral", "qr", "test"].contains(role),
                  let fps = json["fps"] as? NSNumber, CFGetTypeID(fps) != CFBooleanGetTypeID(),
                  fps.doubleValue.isFinite, (1...30).contains(fps.doubleValue),
                  control?.guestCapabilities.contains("vcam_receipt_v3") == true else {
                return ["ok": false, "error": "camera presentation requires an absolute source, role, fps 1...30 and receipt v3"]
            }
            let source = json["source"] as? String ?? "image"
            guard ["image", "video"].contains(source) else { return ["ok": false, "error": "source must be image or video"] }
            let presented = source == "video"
                ? camera.present(videoPath: path, generation: generation, role: role, fps: fps.doubleValue)
                : camera.present(imagePath: path, generation: generation, role: role, fps: fps.doubleValue)
            guard presented else { return ["ok": false, "error": "camera source could not start"] }
            return await confirmation(generation: generation)
        }
        guard type == "camera_status" else { return ["ok": false, "error": "unknown camera operation"] }
        var status = camera.hostStatus(generation: generation)
        if let expected = json["presentation_id"], expected as? String != status["presentation_id"] as? String {
            return ["ok": false, "error": "presentation does not own camera source"]
        }
        if let receipt = await receipt(generation: generation) { status["transport_receipt"] = receipt }
        // Refresh after the await; an interleaved request may have replaced this source.
        let fresh = camera.hostStatus(generation: generation)
        if fresh["presentation_id"] as? String != status["presentation_id"] as? String { status = fresh }
        status["ok"] = true
        status["protocol_version"] = 3
        return status
    }

    private func confirmation(generation: String) async -> [String: Any] {
        let copy = await receipt(generation: generation)
        var result = camera?.hostStatus(generation: generation) ?? [:]
        result["protocol_version"] = 3
        result["ok"] = copy != nil
        if let copy { result["transport_receipt"] = copy }
        else { result["error"] = "two-level camera copy receipt unavailable" }
        return result
    }

    private func receipt(generation: String) async -> [String: Any]? {
        guard let camera, let control, control.isConnected else { return nil }
        let presentation = camera.presentationID
        guard !presentation.isEmpty else { return nil }
        for _ in 0..<30 {
            guard camera.currentGeneration == generation, camera.presentationID == presentation else { return nil }
            guard let value = try? await control.rpcAfterQueuedInput("camera.receipt", params: [:]) else { return nil }
            guard camera.currentGeneration == generation, camera.presentationID == presentation else { return nil }
            if value["generation"] as? String == generation, value["presentation_id"] as? String == presentation,
               let pub = value["vphoned_published_frame_index"] as? Int, let obs = value["libvcam_observed_frame_index"] as? Int,
               pub > 0, obs > 0, obs <= pub,
               let pubAt = value["vphoned_published_at_ns"] as? Int, let obsAt = value["libvcam_observed_at_ns"] as? Int,
               pubAt > 0, obsAt > 0 {
                camera.confirmCopied(generation: generation, presentationID: presentation)
                return value.merging(["semantics": "presentation_frame_copied"]) { _, new in new }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
