import CoreFoundation
import Foundation
import VPhoneCore

/// JSON command semantics, independent of sockets and AppKit views.
@MainActor
final class VPhoneHostCommandExecutor {
    enum BootMode: String { case normal, dfu }
    private let bootMode: BootMode
    private let control: (any VPhoneHostGuest)?
    private let cameraServer: (any VPhoneHostCamera)?
    private let locationProvider: (any VPhoneHostLocation)?
    private let screen: (any VPhoneHostScreen)?

    init(control: (any VPhoneHostGuest)? = nil,
         camera: (any VPhoneHostCamera)? = nil,
         location: (any VPhoneHostLocation)? = nil,
         screen: (any VPhoneHostScreen)? = nil,
         bootMode: BootMode = .normal) {
        self.bootMode = bootMode
        self.control = bootMode == .normal ? control : nil
        cameraServer = bootMode == .normal ? camera : nil
        locationProvider = bootMode == .normal ? location : nil
        self.screen = bootMode == .normal ? screen : nil
    }

    private func captureCompactScreenshot(color: Bool = false) async -> String? {
        guard !Task.isCancelled, let screen, screen.isAvailable else { return nil }
        return await screen.captureCompactScreenshot(color: color)
    }

    func execute(_ data: Data) async -> Data {
        guard let json = try? HostControlIO.decodeRequest(data), let type = json["t"] as? String else {
            return Self.response(ok: false, error: "invalid JSON", extra: ["code": "invalid_json"])
        }
        guard bootMode != .dfu || type == "capabilities" else {
            return Self.response(ok: false, error: "command unavailable in DFU mode",
                                 extra: ["code": "capability_unavailable"])
        }
        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500
        // Return a color (sRGB) image instead of the compact grayscale default.
        // Opt-in so the AI action paths stay lean; the live dashboard sets it.
        let wantColor = json["color"] as? Bool ?? false

        guard (0...60_000).contains(screenDelay) else {
            return Self.response(ok: false, error: "delay must be between 0 and 60000 ms", extra: ["code": "invalid_argument"])
        }
        if Task.isCancelled { return Self.response(ok: false, error: "command cancelled", extra: ["code": "command_cancelled"]) }
        switch type {
        case "capabilities":
            return Self.response(ok: true, extra: capabilitySnapshot())
        case "screenshot":
            let outputPath = json["path"] as? String
            let result = ResultBox()

            await { () async -> Void in
                guard let screen, screen.isAvailable
                else {
                    result.error = "no active VM view"
                    return
                }
                do {
                    if let outputPath {
                        let url = try await screen.saveScreenshot(to: URL(fileURLWithPath: outputPath))
                        result.path = url.path
                    }
                    // Always include compact image for screenshot command
                    result.imageBase64 = await captureCompactScreenshot(color: wantColor)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, path: result.path, image: result.imageBase64)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "tap":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                return Self.response(ok: false, error: "tap requires x and y (pixel coordinates)")
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let screen, screen.isAvailable else {
                    result.error = "no active VM view"
                    return
                }
                guard await screen.tap(x: x, y: y) else {
                    result.error = "gesture queue is full"
                    result.code = "gesture_busy"
                    return
                }
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await captureCompactScreenshot()
                }
            }()
            var tapExtra: [String: Any] = [:]
            if let code = result.code { tapExtra["code"] = code }
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64, extra: tapExtra)

        case "swipe":
            guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                  let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
            else {
                return Self.response(ok: false, error: "swipe requires x1, y1, x2, y2")
            }
            let durationMs = json["ms"] as? Int ?? 300
            guard (0...60_000).contains(durationMs) else {
                return Self.response(ok: false, error: "ms must be between 0 and 60000", extra: ["code": "invalid_argument"])
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let screen, screen.isAvailable else {
                    result.error = "no active VM view"
                    return
                }
                guard await screen.swipe(
                    fromX: x1, fromY: y1, toX: x2, toY: y2,
                    durationMs: durationMs
                ) else {
                    result.error = "gesture queue is full"
                    result.code = "gesture_busy"
                    return
                }
                result.ok = true
                if wantScreen {
                    // The screen adapter has observed this swipe's final event;
                    // wait only for the requested post-gesture settle interval.
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await captureCompactScreenshot()
                }
            }()
            var swipeExtra: [String: Any] = [:]
            if let code = result.code { swipeExtra["code"] = code }
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64, extra: swipeExtra)

        case "key":
            guard let name = json["name"] as? String else {
                return Self.response(ok: false, error: "key requires name (home/power/volup/voldown)")
            }
            let hidKey: (page: UInt32, usage: UInt32)? = switch name {
            case "home": (0x0C, 0x40)
            case "power": (0x0C, 0x30)
            case "volup": (0x0C, 0xE9)
            case "voldown": (0x0C, 0xEA)
            default: nil
            }
            guard let key = hidKey else {
                return Self.response(ok: false, error: "unknown key: \(name)")
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                ctl.sendHIDPress(page: key.page, usage: key.usage)
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await captureCompactScreenshot()
                }
            }()
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64)

        case "type":
            guard let text = json["text"] as? String else {
                return Self.response(ok: false, error: "type requires text")
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.clipboardSet(text: text)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }()
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64)

        case "shell":
            guard let cmd = json["cmd"] as? String, !cmd.isEmpty else {
                return Self.response(ok: false, error: "shell requires cmd")
            }
            let cwd = json["cwd"] as? String
            let timeoutMs = json["timeout_ms"] as? Int
            // Shell is not a UI action — don't capture a screenshot unless asked.
            let wantShellScreen = json["screen"] as? Bool ?? false
            let result = ResultBox()
            let shellBox = ShellBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let res = try await ctl.runShell(command: cmd, cwd: cwd, timeoutMs: timeoutMs)
                    shellBox.stdout = res.stdout
                    shellBox.stderr = res.stderr
                    shellBox.exitCode = res.exitCode
                    shellBox.timedOut = res.timedOut
                    shellBox.truncated = res.truncated
                    result.ok = true
                    if wantShellScreen {
                        result.imageBase64 = await captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                let extra: [String: Any] = [
                    "stdout": shellBox.stdout,
                    "stderr": shellBox.stderr,
                    "code": shellBox.exitCode,
                    "timed_out": shellBox.timedOut,
                    "truncated": shellBox.truncated,
                ]
                return Self.response(ok: true, image: result.imageBase64, extra: extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "file_get":
            guard let path = json["path"] as? String, !path.isEmpty else {
                return Self.response(ok: false, error: "file_get requires path")
            }
            // "save": write the bytes to a host-side path instead of inlining
            // base64 — the sane mode for large payloads like screen recordings.
            let savePath = json["save"] as? String
            let result = ResultBox()
            let box = ExtraBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    box.data = try await ctl.downloadFile(path: path)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            guard result.ok, let fileData = box.data else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }
            guard !Task.isCancelled else {
                return Self.response(ok: false, error: "command_cancelled", extra: ["code": "command_cancelled"])
            }
            if let savePath {
                do {
                    try await Task.detached { try fileData.write(to: URL(fileURLWithPath: savePath)) }.value
                    return Self.response(ok: true, path: savePath,
                                  extra: ["size": fileData.count])
                } catch {
                    return Self.response(ok: false, error: "write \(savePath): \(error)")
                }
            } else {
                return Self.response(ok: true, extra: [
                    "size": fileData.count,
                    "data": fileData.base64EncodedString(),
                ])
            }

        case "file_put":
            guard let path = json["path"] as? String, !path.isEmpty else {
                return Self.response(ok: false, error: "file_put requires path")
            }
            // Content comes either inline ("data_b64") or from a host-side
            // file ("load"); perform host file I/O outside the main actor.
            let payload: Data
            if let b64 = json["data_b64"] as? String {
                guard let decoded = Data(base64Encoded: b64) else {
                    return Self.response(ok: false, error: "data_b64 is not valid base64")
                }
                guard decoded.count <= HostControlIO.maximumInlineBytes else {
                    return Self.response(ok: false, error: "inline file exceeds 1 MiB", extra: ["code": "file_too_large"])
                }
                payload = decoded
            } else if let loadPath = json["load"] as? String {
                do {
                    payload = try await Task.detached { try HostControlIO.loadFile(loadPath) }.value
                } catch {
                    return Self.response(ok: false, error: "cannot read host file: \(loadPath)",
                                  extra: ["code": (error as? HostControlIO.Failure)?.rawValue ?? "io_error"])
                }
            } else {
                return Self.response(ok: false, error: "file_put requires data_b64 or load")
            }
            guard !Task.isCancelled else {
                return Self.response(ok: false, error: "command_cancelled", extra: ["code": "command_cancelled"])
            }
            let perm = json["perm"] as? String ?? "644"
            let result = ResultBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.uploadFile(path: path, data: payload, permissions: perm)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, extra: ["size": payload.count])
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "app_launch":
            guard let bundleId = json["bundle_id"] as? String, !bundleId.isEmpty else {
                return Self.response(ok: false, error: "app_launch requires bundle_id")
            }
            let url = json["url"] as? String
            let result = ResultBox()
            let box = ExtraBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let pid = try await ctl.appLaunch(bundleId: bundleId, url: url)
                    box.extra["pid"] = pid
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, image: result.imageBase64, extra: box.extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "app_terminate":
            guard let bundleId = json["bundle_id"] as? String, !bundleId.isEmpty else {
                return Self.response(ok: false, error: "app_terminate requires bundle_id")
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.appTerminate(bundleId: bundleId)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }()
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64)

        case "app_list":
            let filter = json["filter"] as? String ?? "all"
            let result = ResultBox()
            let box = ExtraBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let apps = try await ctl.appList(filter: filter)
                    box.extra["apps"] = apps.map { app -> [String: Any] in
                        [
                            "bundle_id": app.bundleId,
                            "name": app.name,
                            "version": app.version,
                            "type": app.type,
                            "state": app.state,
                            "pid": app.pid,
                            "path": app.path,
                            "data_container": app.dataContainer,
                        ]
                    }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, extra: box.extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "app_foreground":
            let result = ResultBox()
            let box = ExtraBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let fg = try await ctl.appForeground()
                    box.extra["bundle_id"] = fg.bundleId
                    box.extra["name"] = fg.name
                    box.extra["pid"] = fg.pid
                    if !fg.source.isEmpty { box.extra["source"] = fg.source }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, extra: box.extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "open_url":
            guard let url = json["url"] as? String, !url.isEmpty else {
                return Self.response(ok: false, error: "open_url requires url")
            }
            let result = ResultBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.openURL(url)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }()
            return Self.response(ok: result.ok, error: result.error, image: result.imageBase64)

        case "ipa_install":
            // Install an IPA already present on the guest filesystem, using
            // vphoned's built-in installer. The host streams nothing here — the
            // caller (e.g. autophone) has already placed the .ipa at `path` on
            // the guest, so we just relay the request over the control channel
            // and surface the guest's response verbatim.
            guard let path = json["path"] as? String, !path.isEmpty else {
                return Self.response(ok: false, error: "ipa_install requires path")
            }
            let registration = json["registration"] as? String ?? "User"
            let certPath = json["cert_path"] as? String
            let result = ResultBox()
            let box = ExtraBox()

            await { () async -> Void in
                guard let ctl = control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                var req: [String: Any] = [
                    "t": "ipa_install", "path": path, "registration": registration,
                ]
                if let certPath { req["cert_path"] = certPath }
                do {
                    let (resp, _) = try await ctl.sendRequest(req)
                    if let msg = resp["msg"] as? String { box.extra["msg"] = msg }
                    if let bundleId = resp["bundle_id"] as? String { box.extra["bundle_id"] = bundleId }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, extra: box.extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "unknown error")
            }

        case "camera_present":
            // Present an image or looping video through the synthetic camera
            // under a fresh generation/role (§8.1). Fail-closed: ok=true only
            // once the two-level transport receipt (vphoned published +
            // libvcamcaptured observed) confirms the requested generation via
            // the guest 1337 vcam_status channel — a host publish alone is not
            // success (invariant #7).
            guard let path = json["path"] as? String, !path.isEmpty else {
                return Self.response(ok: false, error: "camera_present requires path")
            }
            let source = json["source"] as? String ?? "image"
            guard ["image", "video"].contains(source) else {
                return Self.response(ok: false, error: "camera_present source must be image|video",
                                     extra: ["code": "invalid_argument"])
            }
            guard let generation = json["generation"] as? String, Self.validCameraGeneration(generation) else {
                return Self.response(ok: false, error: "camera_present requires 1...79 UTF-8 bytes of generation without NUL")
            }
            let role = json["role"] as? String ?? "qr"
            guard ["neutral", "qr", "test"].contains(role) else {
                return Self.response(ok: false, error: "camera_present role must be neutral|qr|test")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return Self.response(ok: false, error: "camera_present path not found: \(path)")
            }
            let fps = (json["fps"] as? Double) ?? (json["fps"] as? Int).map(Double.init) ?? 8.0

            let result = ResultBox()
            let box = ExtraBox()
            await { () async -> Void in
                guard let cam = cameraServer else {
                    result.error = "no camera server"
                    return
                }
                guard control?.guestCaps.contains("vcam_receipt_v3") == true else {
                    result.error = "camera receipt v3 requires updated vphoned and libvcamcaptured"
                    return
                }
                let presented: Bool
                if source == "video" {
                    presented = cam.present(videoPath: path, generation: generation, role: role, fps: fps)
                } else {
                    presented = cam.present(imagePath: path, generation: generation, role: role, fps: fps)
                }
                guard presented else {
                    result.error = "camera vsock not connected or \(source) load failed"
                    return
                }
                // Query a same-generation copy receipt; this does not verify app display or QR recognition.
                let presentationID = cam.hostStatus(generation: generation)["presentation_id"] as? String ?? ""
                let receipt = await Self.cameraTransportReceipt(
                    controller: self, generation: generation, presentationID: presentationID)
                box.extra["protocol_version"] = 3
                box.extra["presentation_id"] = presentationID
                box.extra["source"] = source
                box.extra["role"] = role
                box.extra["generation"] = generation
                box.extra["streaming"] = cam.hostStatus(generation: generation)["streaming"]
                if let receipt {
                    box.extra["transport_receipt"] = receipt
                    result.ok = true
                } else {
                    result.error = "two-level transport receipt unavailable for \(generation)"
                }
            }()
            if result.ok {
                return Self.response(ok: true, extra: box.extra)
            } else {
                return Self.response(ok: false, error: result.error ?? "camera_present failed",
                              extra: box.extra)
            }

        case "camera_status":
            guard let generation = json["generation"] as? String, Self.validCameraGeneration(generation) else {
                return Self.response(ok: false, error: "camera_status requires 1...79 UTF-8 bytes of generation without NUL")
            }
            let result = ResultBox()
            let box = ExtraBox()
            await { () async -> Void in
                guard let cam = cameraServer else {
                    result.error = "no camera server"
                    return
                }
                let presentationID = json["presentation_id"] as? String
                    ?? cam.hostStatus(generation: generation)["presentation_id"] as? String ?? ""
                let receipt = await Self.cameraTransportReceipt(controller: self, generation: generation,
                                                               presentationID: presentationID)
                // Re-read after the await: another request may have stopped/switched the source.
                box.extra = cam.hostStatus(generation: generation)
                if let receipt { box.extra["transport_receipt"] = receipt }
                result.ok = true
            }()
            return Self.response(ok: result.ok, error: result.error, extra: box.extra)

        case "camera_stop":
            guard let generation = json["generation"] as? String, Self.validCameraGeneration(generation) else {
                return Self.response(ok: false, error: "camera_stop requires 1...79 UTF-8 bytes of generation without NUL")
            }
            guard let cam = cameraServer else { return Self.response(ok: false, error: "no camera server") }
            let status = cam.hostStatus(generation: generation)
            guard status["generation"] as? String == generation else {
                return Self.response(ok: false, error: "generation does not own the camera source")
            }
            if let expected = json["presentation_id"] {
                guard let expected = expected as? String,
                      expected == status["presentation_id"] as? String else {
                    return Self.response(ok: false, error: "presentation does not own the camera source")
                }
            }
            let policy = json["policy"] as? String ?? "keep_last"
            guard json["policy"] == nil || json["policy"] is String,
                  ["keep_last", "neutral"].contains(policy) else {
                return Self.response(ok: false, error: "camera_stop policy must be keep_last|neutral")
            }
            if policy == "keep_last" {
                let stopped = cam.stop(generation: generation)
                return Self.response(ok: stopped, extra: ["stop_policy": policy, "streaming": false,
                                                         "guest_frame_cleared": false])
            }
            guard cam.isConnected, control?.isConnected == true,
                  control?.guestCaps.contains("vcam_receipt_v3") == true else {
                return Self.response(ok: false, error: "neutral presentation requires camera connection and receipt v3")
            }
            let neutralGeneration = UUID().uuidString
            guard cam.presentNeutral(generation: neutralGeneration, fps: 8) else {
                return Self.response(ok: false, error: "neutral source could not start")
            }
            let presentationID = cam.hostStatus(generation: neutralGeneration)["presentation_id"] as? String ?? ""
            let receipt = await Self.cameraTransportReceipt(controller: self, generation: neutralGeneration,
                                                           presentationID: presentationID)
            var extra = cam.hostStatus(generation: neutralGeneration)
            extra["stop_policy"] = policy
            extra["protocol_version"] = 3
            extra["neutral_generation"] = neutralGeneration
            if let receipt { extra["transport_receipt"] = receipt }
            return Self.response(ok: receipt != nil,
                                 error: receipt == nil ? "neutral transport receipt unavailable" : nil, extra: extra)

        case "location_source_set", "location_stream_start", "location_stream_push",
             "location_source_control", "location_source_status", "location_source_stop":
            let result = ResultBox()
            await { () async -> Void in
                guard let provider = locationProvider else {
                    result.error = "location provider unavailable"
                    result.code = "location_guest_unavailable"
                    return
                }
                let systemController = provider.systemLocationController
                do {
                    let snapshot: [String: Any]
                    switch type {
                    case "location_source_set":
                        guard (json["mode"] as? String) == "fixed" else {
                            throw VPhoneSystemLocationError(
                                code: "invalid_location_source",
                                message: "location_source_set mode must be fixed")
                        }
                        try Self.requireWGS84(json)
                        let owner = try Self.locationString(json, key: "owner")
                        let heartbeat = try Self.locationDouble(
                            json, key: "heartbeat_s", defaultValue: 1.0)
                        let fix = try Self.systemLocationFix(json)
                        let replace = try Self.locationBool(
                            json, key: "replace", defaultValue: false)
                        let persist = try Self.locationBool(
                            json, key: "persist", defaultValue: false)
                        try systemController.preflightFixedSource(
                            owner: owner,
                            fix: fix,
                            heartbeatSeconds: heartbeat,
                            replace: replace,
                            persist: persist)
                        let ownership = provider.externalControlCheck()
                        snapshot = try await systemController.setFixed(
                            owner: owner, fix: fix, heartbeatSeconds: heartbeat,
                            replace: replace,
                            persist: persist,
                            precommit: {
                                try ownership()
                            })
                    case "location_stream_start":
                        try Self.requireWGS84(json)
                        let owner = try Self.locationString(json, key: "owner")
                        let watchdog = try Self.locationDouble(
                            json, key: "watchdog_s", defaultValue: 3.0)
                        let timeoutAction = try Self.locationString(
                            json, key: "on_timeout", defaultValue: "hold")
                        let replace = try Self.locationBool(
                            json, key: "replace", defaultValue: false)
                        try systemController.preflightStreamSource(
                            owner: owner,
                            watchdogSeconds: watchdog,
                            onTimeout: timeoutAction,
                            replace: replace)
                        let ownership = provider.externalControlCheck()
                        snapshot = try await systemController.startStream(
                            owner: owner,
                            watchdogSeconds: watchdog,
                            onTimeout: timeoutAction,
                            replace: replace,
                            precommit: {
                                try ownership()
                            })
                    case "location_stream_push":
                        let generation = try Self.locationString(
                            json, key: "generation")
                        let fix = try Self.systemLocationFix(json)
                        snapshot = try await systemController.push(
                            generation: generation, fix: fix)
                    case "location_source_control":
                        let paused = try Self.locationBool(json, key: "paused")
                        let generation = try Self.locationString(
                            json, key: "generation")
                        snapshot = try await systemController.setPaused(
                            paused, generation: generation)
                    case "location_source_status":
                        snapshot = systemController.snapshot()
                    case "location_source_stop":
                        let generation = try Self.locationString(
                            json, key: "generation")
                        snapshot = try await systemController.stop(
                            generation: generation)
                    default:
                        preconditionFailure("unreachable location command")
                    }
                    result.ok = true
                    result.extra = snapshot
                } catch let error as VPhoneSystemLocationError {
                    result.code = error.code
                    result.error = error.message
                } catch {
                    result.code = "location_delivery_rejected"
                    result.error = error.localizedDescription
                }
            }()
            var extra = result.extra
            if let code = result.code { extra["code"] = code }
            return Self.response(ok: result.ok, error: result.error, extra: extra)

        case "location":
            // Push a simulated GPS fix into the guest's system-wide
            // CLSimulationManager (same channel the GUI location menu drives).
            // Fail-closed on the automation surface: reject out-of-range params,
            // require the guest to advertise the "location" capability, and wait
            // for the guest's ack (encode/disconnect/write/timeout all → ok:false).
            let lat: Double
            let lon: Double
            let alt: Double
            let hacc: Double
            let vacc: Double
            let speed: Double
            let course: Double
            do {
                lat = try Self.locationDouble(json, key: "lat")
                lon = try Self.locationDouble(json, key: "lon")
                alt = try Self.locationDouble(json, key: "alt", defaultValue: 0)
                hacc = try Self.locationDouble(json, key: "hacc", defaultValue: 5)
                vacc = try Self.locationDouble(json, key: "vacc", defaultValue: 5)
                speed = try Self.locationDouble(json, key: "speed", defaultValue: 0)
                course = try Self.locationDouble(json, key: "course", defaultValue: -1)
            } catch let error as VPhoneSystemLocationError {
                return Self.response(ok: false, error: error.message)
            } catch {
                return Self.response(ok: false, error: error.localizedDescription)
            }
            if let verr = Self.locationValidationError(
                lat: lat, lon: lon, alt: alt, hacc: hacc,
                vacc: vacc, speed: speed, course: course
            ) {
                return Self.response(ok: false, error: verr)
            }
            let result = ResultBox()
            await { () async -> Void in
                guard let provider = locationProvider else {
                    result.error = "location provider unavailable"
                    return
                }
                guard let control, control.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                guard control.guestCaps.contains("location") else {
                    result.error = "guest does not support location simulation"
                    return
                }
                // Take ownership of the guest location source: stop any Mac-location
                // forwarding or route replay so this fixed fix isn't overwritten by
                // the provider's next update (headless auto-forwards on connect; the
                // GUI menu may be syncing or replaying a route). Ownership persists
                // across guest reconnects until a GUI source is chosen again.
                print("[location] deprecated host command 'location'; use location_source_set or stream")
                do {
                    let legacyFix = VPhoneSystemLocationFix(
                        producerSequence: 0,
                        latitude: lat, longitude: lon, altitude: alt,
                        horizontalAccuracy: hacc, verticalAccuracy: vacc,
                        speed: speed, course: course,
                        timestamp: Date().timeIntervalSince1970)
                    if control.guestCaps.contains("location_owned") {
                        try provider.systemLocationController.preflightFixedSource(
                            owner: "legacy-uds",
                            fix: legacyFix,
                            heartbeatSeconds: 1.0,
                            replace: true,
                            persist: false)
                        let ownership = provider.externalControlCheck()
                        _ = try await provider.systemLocationController.setFixed(
                            owner: "legacy-uds",
                            fix: legacyFix,
                            heartbeatSeconds: 1.0,
                            replace: true,
                            precommit: {
                                try ownership()
                            })
                    } else {
                        let ownership = provider.externalControlCheck()
                        _ = try await provider.systemLocationController.clearLegacyLocation(
                            consistencyCheck: {
                                try ownership()
                            },
                            guestOperation: {
                                try await Self.sendLegacyLocation(
                                    legacyFix, control: control)
                            },
                            guestRollback: { rollbackFix in
                                try await Self.sendLegacyLocation(
                                    rollbackFix, control: control)
                            })
                    }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            return Self.response(ok: result.ok, error: result.error)

        case "location_stop":
            let result = ResultBox()
            await { () async -> Void in
                guard let provider = locationProvider else {
                    result.error = "location provider unavailable"
                    return
                }
                guard let control, control.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                guard control.guestCaps.contains("location") else {
                    result.error = "guest does not support location simulation"
                    return
                }
                print("[location] deprecated host command 'location_stop'; use location_source_stop")
                do {
                    if control.guestCaps.contains("location_owned") {
                        // Silence the provider and hold ownership, else a live
                        // forwarder or reconnect would re-inject after the clear.
                        let ownership = provider.externalControlCheck()
                        _ = try await provider.systemLocationController.clearLegacyLocation(
                            consistencyCheck: {
                                try ownership()
                            })
                    } else {
                        let ownership = provider.externalControlCheck()
                        _ = try await provider.systemLocationController.clearLegacyLocation(
                            consistencyCheck: {
                                try ownership()
                            },
                            guestOperation: {
                                try await Self.sendLegacyLocation(
                                    nil, control: control)
                            },
                            guestRollback: { rollbackFix in
                                try await Self.sendLegacyLocation(
                                    rollbackFix, control: control)
                            })
                    }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }()
            return Self.response(ok: result.ok, error: result.error)

        default:
            return Self.response(ok: false, error: "unknown command: \(type)")
        }
    }

    /// `apps_v2` guests declare `app_launch` separately (only when uiopen is
    /// executable). Guests without `apps_v2` predate the split: their `apps`
    /// capability implied app_launch, so keep that meaning for them.
    static func guestDeclaresAppLaunch(_ caps: [String]) -> Bool {
        guard caps.contains("apps") else { return false }
        return caps.contains("apps_v2") ? caps.contains("app_launch") : true
    }

    private func capabilitySnapshot() -> [String: Any] {
        let connected = control?.isConnected == true
        let caps = connected ? (control?.guestCaps ?? []) : []
        let visible = screen?.isAvailable == true
        var commands: [String: Bool] = ["capabilities": true, "screenshot": visible,
                                      "tap": visible, "swipe": visible]
        for (names, capability) in [
            (["key"], "hid"), (["type"], "clipboard"), (["shell"], "shell"),
            (["file_get", "file_put"], "file"),
            (["app_terminate", "app_list", "app_foreground"], "apps"),
            (["open_url"], "url"), (["ipa_install"], "ipa_install"),
        ] {
            for name in names { commands[name] = connected && caps.contains(capability) }
        }
        commands["app_launch"] = connected && Self.guestDeclaresAppLaunch(caps)
        for name in ["location", "location_stop"] {
            commands[name] = locationProvider != nil && caps.contains("location")
        }
        for name in ["location_source_set", "location_stream_start", "location_stream_push",
                     "location_source_control", "location_source_stop"] {
            commands[name] = locationProvider != nil && caps.contains("location_owned")
        }
        commands["location_source_status"] = locationProvider != nil
        commands["camera_present"] = cameraServer?.isConnected == true && caps.contains("vcam_receipt_v3")
        commands["camera_status"] = cameraServer != nil
        commands["camera_stop"] = cameraServer != nil
        return ["protocol_version": 1, "boot_mode": bootMode.rawValue, "guest_connected": connected,
                "guest_capabilities": caps, "screen_available": visible,
                "commands": commands,
                "limits": ["request_bytes": HostControlIO.maximumRequestBytes,
                           "inline_file_bytes": HostControlIO.maximumInlineBytes,
                           "host_file_bytes": HostControlIO.maximumFileBytes,
                           "connections": HostControlIO.maximumConnections,
                           "command_timeout_ms": VPhoneHostCommandService.defaultTimeoutMilliseconds]]
    }

    /// Command-local state, confined to the main actor.
    private final class ResultBox {
        var path: String?
        var error: String?
        var code: String?
        var ok = false
        var imageBase64: String?
        var extra: [String: Any] = [:]
    }

    /// Command-local shell output.
    private final class ShellBox {
        var stdout = ""
        var stderr = ""
        var exitCode = -1
        var timedOut = false
        var truncated = false
    }

    /// Command-local structured extra fields and raw payloads from the
    /// proxied guest-capability commands (file_*, app_*, open_url).
    private final class ExtraBox {
        var extra: [String: Any] = [:]
        var data: Data?
    }

    private static func sendLegacyLocation(
        _ fix: VPhoneSystemLocationFix?,
        control: any VPhoneHostGuest
    ) async throws {
        let payload: [String: Any]
        let fallback: String
        if let fix {
            payload = [
                "t": "location",
                "lat": fix.latitude,
                "lon": fix.longitude,
                "alt": fix.altitude,
                "hacc": fix.horizontalAccuracy,
                "vacc": fix.verticalAccuracy,
                "speed": fix.speed,
                "course": fix.course,
            ]
            fallback = "guest rejected location"
        } else {
            payload = ["t": "location_stop"]
            fallback = "guest rejected location_stop"
        }

        let response: [String: Any]
        do {
            (response, _) = try await control.sendRequest(payload)
        } catch let error as VPhoneControl.ControlError {
            throw VPhoneControlLocationGuestAdapter.map(error)
        }
        guard (response["t"] as? String) == "ok" else {
            throw VPhoneSystemLocationError(
                code: response["code"] as? String ?? "location_delivery_rejected",
                message: response["msg"] as? String ?? fallback,
                definitiveGuestRejection: true)
        }
    }

    /// Validate a simulated-location parameter set at the automation boundary.
    /// Returns an error message when the values could not produce a valid fix,
    /// or nil when they are acceptable. Kept pure (no I/O) so it is unit-testable
    /// and so the protocol edge rejects bad input before any guest round-trip.
    private nonisolated static func requireWGS84(_ json: [String: Any]) throws {
        guard (json["coordinate_system"] as? String)?.lowercased() == "wgs84" else {
            throw VPhoneSystemLocationError(
                code: "invalid_location_source",
                message: "coordinate_system must be wgs84")
        }
    }

    nonisolated static func locationDouble(
        _ json: [String: Any],
        key: String,
        defaultValue: Double? = nil
    ) throws -> Double {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a number")
        }
        guard let number = strictJSONNumber(raw) else {
            throw invalidLocationField(key, expected: "a number")
        }
        return number.doubleValue
    }

    nonisolated static func locationInteger(
        _ json: [String: Any],
        key: String
    ) throws -> Int {
        let value = try locationDouble(json, key: key)
        let maximumSafeJSONInteger = 9_007_199_254_740_991.0
        guard value.isFinite,
              abs(value) <= maximumSafeJSONInteger,
              let integer = Int(exactly: value)
        else {
            throw invalidLocationField(key, expected: "a safe integer")
        }
        return integer
    }

    nonisolated static func locationBool(
        _ json: [String: Any],
        key: String,
        defaultValue: Bool? = nil
    ) throws -> Bool {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a boolean")
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            throw invalidLocationField(key, expected: "a boolean")
        }
        return number.boolValue
    }

    nonisolated static func locationString(
        _ json: [String: Any],
        key: String,
        defaultValue: String? = nil
    ) throws -> String {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a string")
        }
        guard let value = raw as? String else {
            throw invalidLocationField(key, expected: "a string")
        }
        return value
    }

    private nonisolated static func strictJSONNumber(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    private nonisolated static func invalidLocationField(
        _ key: String,
        expected: String
    ) -> VPhoneSystemLocationError {
        VPhoneSystemLocationError(
            code: "invalid_location_source",
            message: "\(key) must be \(expected)")
    }

    nonisolated static func systemLocationFix(
        _ json: [String: Any]
    ) throws -> VPhoneSystemLocationFix {
        let sequence = try locationInteger(json, key: "producer_sequence")
        let lat = try locationDouble(json, key: "lat")
        let lon = try locationDouble(json, key: "lon")
        let timestamp: TimeInterval
        if json["timestamp"] == nil {
            timestamp = 0
        } else if let text = json["timestamp"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let regular = ISO8601DateFormatter()
            guard let date = fractional.date(from: text) ?? regular.date(from: text) else {
                throw VPhoneSystemLocationError(
                    code: "invalid_location_source", message: "timestamp must be ISO-8601")
            }
            timestamp = date.timeIntervalSince1970
        } else if let raw = json["timestamp"], let numeric = strictJSONNumber(raw) {
            timestamp = numeric.doubleValue
        } else {
            throw invalidLocationField(
                "timestamp", expected: "a number or ISO-8601 string")
        }
        return VPhoneSystemLocationFix(
            producerSequence: sequence,
            latitude: lat, longitude: lon,
            altitude: try locationDouble(json, key: "alt", defaultValue: 0),
            horizontalAccuracy: try locationDouble(json, key: "hacc", defaultValue: 5),
            verticalAccuracy: try locationDouble(json, key: "vacc", defaultValue: 5),
            speed: try locationDouble(json, key: "speed", defaultValue: 0),
            course: try locationDouble(json, key: "course", defaultValue: -1),
            timestamp: timestamp)
    }

    nonisolated static func locationValidationError(
        lat: Double, lon: Double, alt: Double,
        hacc: Double, vacc: Double, speed: Double, course: Double
    ) -> String? {
        VPhoneSystemLocationValidation.error(
            latitude: lat,
            longitude: lon,
            altitude: alt,
            horizontalAccuracy: hacc,
            verticalAccuracy: vacc,
            speed: speed,
            course: course)
    }

    nonisolated static func validCameraGeneration(_ generation: String) -> Bool {
        !generation.isEmpty && generation.utf8.count < 80 && !generation.utf8.contains(0)
    }

    private func cameraSourceIsActive(generation: String, presentationID: String) -> Bool {
        guard let cameraServer, cameraServer.isConnected else { return false }
        let status = cameraServer.hostStatus(generation: generation)
        return !presentationID.isEmpty && status["presentation_id"] as? String == presentationID
            && status["generation"] as? String == generation && status["streaming"] as? Bool == true
    }

    /// Confirm that libvcamcaptured copied at least one frame of the active
    /// generation from vphoned's shared memory. Both indices are publisher-local:
    /// observation may lag publication. Neither is the host wire `fi`, and this
    /// receipt does not establish app display or QR recognition.
    @MainActor
    private static func cameraTransportReceipt(
        controller: VPhoneHostCommandExecutor, generation: String, presentationID: String
    ) async -> [String: Any]? {
        guard let ctl = controller.control, ctl.isConnected else { return nil }
        // Give the guest a brief window to publish + observe the first frame.
        for _ in 0..<20 {
            guard !Task.isCancelled, ctl.isConnected,
                  controller.cameraSourceIsActive(generation: generation, presentationID: presentationID) else { return nil }
            guard let (resp, _) = try? await ctl.sendRequest(
                ["t": "vcam_status", "generation": generation, "presentation_id": presentationID])
            else { return nil }
            guard !Task.isCancelled, ctl.isConnected,
                  controller.cameraSourceIsActive(generation: generation, presentationID: presentationID) else { return nil }
            if let pub = resp["vphoned_published_frame_index"] as? Int,
               let obs = resp["libvcam_observed_frame_index"] as? Int,
               (resp["generation"] as? String) == generation,
               (resp["presentation_id"] as? String) == presentationID,
               pub > 0, obs > 0, obs <= pub {
                return [
                    "semantics": "presentation_frame_copied",
                    "presentation_id": presentationID,
                    "generation": generation,
                    "vphoned_published_frame_index": pub,
                    "libvcam_observed_frame_index": obs,
                    "vphoned_published_at_ns": resp["vphoned_published_at_ns"] as? Int ?? 0,
                    "libvcam_observed_at_ns": resp["libvcam_observed_at_ns"] as? Int ?? 0,
                ]
            }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
        return nil
    }

    nonisolated static func response(
        ok: Bool, path: String? = nil, error: String? = nil, image: String? = nil,
        extra: [String: Any]? = nil
    ) -> Data {
        var dict: [String: Any] = ["ok": ok]
        if let path { dict["path"] = path }
        if let error { dict["error"] = error }
        if let image { dict["image"] = image }
        if let extra { dict.merge(extra) { _, new in new } }

        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"ok\":false,\"error\":\"response encoding failed\"}".utf8)
    }
}
