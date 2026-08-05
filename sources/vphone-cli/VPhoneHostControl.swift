import AppKit
import Foundation
import ImageIO

// MARK: - Host Control Socket

/// Lightweight Unix domain socket server that accepts automation commands from
/// local processes (e.g. Claude Code via `nc -U`).  One JSON line in, one JSON
/// line out, then the connection closes.
///
/// Every response includes an `"image"` field with a compact base64-encoded
/// grayscale JPEG of the current screen (unless `"screen":false` is sent).
///
/// Supported commands:
///   {"t":"screenshot"}                          → full-res save to Desktop (or explicit path)
///   {"t":"screenshot","path":"/tmp/shot.png"}   → save to explicit path (PNG/JPEG by extension)
///   {"t":"tap","x":645,"y":1398}                → tap at pixel coordinates
///   {"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}  → swipe
///   {"t":"key","name":"home"}                   → hardware key (home/power/volup/voldown)
///   {"t":"type","text":"Hello"}                 → set guest clipboard
///   {"t":"shell","cmd":"uname -a"}              → run command on guest via /bin/sh -c
///         optional: "cwd", "timeout_ms"; response carries stdout/stderr/code/timed_out
///   {"t":"file_get","path":"/var/...","save":"/tmp/x"}  → pull guest file; "save" writes
///         to a host path, otherwise response carries base64 "data" (+ "size")
///   {"t":"file_put","path":"/var/...","data_b64":...}   → push file; or "load" reads a
///         host path; optional "perm" (default "644")
///   {"t":"app_launch","bundle_id":"com.x.y"}    → launch app (optional "url"); returns pid
///   {"t":"app_terminate","bundle_id":"com.x.y"} → kill app
///   {"t":"app_list","filter":"all"}             → installed apps ("apps" array)
///   {"t":"app_foreground"}                      → frontmost app (bundle_id/name/pid/source);
///                                                  source="sbs" trustworthy, "unknown" = could not determine
///   {"t":"open_url","url":"https://..."}        → open URL on guest
///
/// The UI commands ("tap", "swipe", "key", "type", "app_launch",
/// "app_terminate", "open_url") wait briefly then capture a compact screen
/// image returned as `"image":"<base64>"` in the response; pass
/// `"screen":false` to skip it. "screenshot" always returns an image. The
/// non-UI commands ("shell", "file_*", "app_list", "app_foreground") never
/// attach one (for "shell", pass `"screen":true` to opt in).
///
/// Connections are handled concurrently — a long-running command does not
/// block other clients.
@MainActor
class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder: VPhoneScreenRecorder?
    private weak var control: VPhoneControl?
    private weak var cameraServer: VPhoneCameraServer?
    private weak var locationProvider: VPhoneLocationProvider?

    /// Thread-safe box for passing results between main actor and accept queue.
    private final class ResultBox: @unchecked Sendable {
        var path: String?
        var error: String?
        var code: String?
        var ok = false
        var imageBase64: String?
        var extra: [String: Any] = [:]
    }

    /// Thread-safe box for guest shell output passed back from the main actor.
    private final class ShellBox: @unchecked Sendable {
        var stdout = ""
        var stderr = ""
        var exitCode = -1
        var timedOut = false
        var truncated = false
    }

    /// Thread-safe box for structured extra fields + raw payloads from the
    /// proxied guest-capability commands (file_*, app_*, open_url).
    private final class ExtraBox: @unchecked Sendable {
        var extra: [String: Any] = [:]
        var data: Data?
    }

    /// Screen pixel dimensions for coordinate mapping.
    private var screenWidth: Int = 1290
    private var screenHeight: Int = 2796

    /// Compact screenshot scale factor (1/3 = 430x932).
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(
        captureView: VPhoneVirtualMachineView,
        screenRecorder: VPhoneScreenRecorder,
        control: VPhoneControl,
        cameraServer: VPhoneCameraServer?,
        locationProvider: VPhoneLocationProvider?,
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
        self.cameraServer = cameraServer
        self.locationProvider = locationProvider
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 4) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        let capturedFD = fd
        acceptQueue.async { [weak self] in
            Self.acceptLoop(listenFD: capturedFD, controller: self)
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Compact Screenshot

    /// Capture current screen as a small JPEG, returned as base64.
    ///
    /// Defaults to a compact grayscale JPEG (the AI path: small + fast). Pass
    /// `color: true` (the `"color":true` socket flag) for an sRGB JPEG at higher
    /// quality — used by the live dashboard so its stream matches the on-screen
    /// vphone-cli window. The underlying capture is always color (32BGRA); only
    /// the encode differs.
    private func captureCompactScreenshot(color: Bool = false) async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil else {
            return nil
        }

        // Reuse the existing private-API capture
        guard let cgImage = await captureStillImage(recorder: recorder, view: view) else {
            return nil
        }

        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        let ctx: CGContext?
        if color {
            // sRGB context, premultiplied alpha (BGRA-compatible).
            ctx = CGContext(
                data: nil, width: dstW, height: dstH,
                bitsPerComponent: 8, bytesPerRow: dstW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        } else {
            // Grayscale context (compact, high-contrast — the AI default).
            ctx = CGContext(
                data: nil, width: dstW, height: dstH,
                bitsPerComponent: 8, bytesPerRow: dstW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let ctx else { return nil }

        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let outImage = ctx.makeImage() else { return nil }

        // Color: a touch more quality since it's for human viewing; gray stays lean.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let quality: CGFloat = color ? 0.6 : 0.35
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, outImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// Access the recorder's private capture method via the existing async wrapper.
    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        // Use the public saveScreenshot path but intercept before encoding.
        // We call the recorder's internal captureStillImage indirectly by
        // going through saveScreenshot to a temp file, then reading back.
        // This is suboptimal but avoids exposing internal API.
        //
        // Better: use the same private API directly.
        guard let vmView = view as? VPhoneVirtualMachineView,
              let display = vmView.recordingGraphicsDisplay
        else { return nil }

        return await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
            guard display.responds(to: selector),
                  let cls = object_getClass(display),
                  let method = class_getInstanceMethod(cls, selector)
            else {
                continuation.resume(returning: nil)
                return
            }

            typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
            typealias IMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

            let impl = method_getImplementation(method)
            let fn = unsafeBitCast(impl, to: IMP.self)

            let block: CompletionBlock = { imageObject in
                guard let imageObject else {
                    continuation.resume(returning: nil)
                    return
                }
                if let nsImage = imageObject as? NSImage {
                    continuation.resume(returning: nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    return
                }
                let cf = imageObject as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    continuation.resume(returning: (cf as! CGImage))
                    return
                }
                continuation.resume(returning: nil)
            }
            let blockObj = unsafeBitCast(block, to: AnyObject.self)
            fn(display, selector, blockObj)
        }
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(listenFD: Int32, controller: VPhoneHostControl?) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            // Handle each client on its own worker: commands that block for a
            // while (a long guest shell, a large file_get) must not freeze the
            // rest of the socket surface. Per-command ordering on the guest is
            // still enforced by the vsock request pipeline.
            DispatchQueue.global(qos: .userInitiated).async { [weak controller] in
                handleClient(clientFD, controller: controller)
            }
        }
    }

    private nonisolated static func handleClient(_ fd: Int32, controller: VPhoneHostControl?) {
        defer { close(fd) }

        guard let line = readLine(from: fd) else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String
        else {
            writeResponse(fd, ok: false, error: "invalid JSON")
            return
        }

        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500
        // Return a color (sRGB) image instead of the compact grayscale default.
        // Opt-in so the AI action paths stay lean; the live dashboard sets it.
        let wantColor = json["color"] as? Bool ?? false

        switch type {
        case "screenshot":
            let outputPath = json["path"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller,
                      let recorder = controller.screenRecorder,
                      let view = controller.captureView,
                      view.window != nil
                else {
                    result.error = "no active VM view"
                    return
                }
                do {
                    if let outputPath {
                        let url = try await recorder.saveScreenshot(view: view, to: URL(fileURLWithPath: outputPath))
                        result.path = url.path
                    }
                    // Always include compact image for screenshot command
                    result.imageBase64 = await controller.captureCompactScreenshot(color: wantColor)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, path: result.path, image: result.imageBase64)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "tap":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                writeResponse(fd, ok: false, error: "tap requires x and y (pixel coordinates)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectTap(
                    pixelX: x, pixelY: y,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight
                )
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "swipe":
            guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                  let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
            else {
                writeResponse(fd, ok: false, error: "swipe requires x1, y1, x2, y2")
                return
            }
            let durationMs = json["ms"] as? Int ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectSwipe(
                    fromX: x1, fromY: y1, toX: x2, toY: y2,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight,
                    durationMs: durationMs
                )
                result.ok = true
                if wantScreen {
                    // Wait for swipe to finish + settle
                    let totalDelay = durationMs + screenDelay
                    try? await Task.sleep(nanoseconds: UInt64(totalDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "key":
            guard let name = json["name"] as? String else {
                writeResponse(fd, ok: false, error: "key requires name (home/power/volup/voldown)")
                return
            }
            let hidKey: (page: UInt32, usage: UInt32)? = switch name {
            case "home": (0x0C, 0x40)
            case "power": (0x0C, 0x30)
            case "volup": (0x0C, 0xE9)
            case "voldown": (0x0C, 0xEA)
            default: nil
            }
            guard let key = hidKey else {
                writeResponse(fd, ok: false, error: "unknown key: \(name)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                ctl.sendHIDPress(page: key.page, usage: key.usage)
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "type":
            guard let text = json["text"] as? String else {
                writeResponse(fd, ok: false, error: "type requires text")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.clipboardSet(text: text)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "shell":
            guard let cmd = json["cmd"] as? String, !cmd.isEmpty else {
                writeResponse(fd, ok: false, error: "shell requires cmd")
                return
            }
            let cwd = json["cwd"] as? String
            let timeoutMs = json["timeout_ms"] as? Int
            // Shell is not a UI action — don't capture a screenshot unless asked.
            let wantShellScreen = json["screen"] as? Bool ?? false
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let shellBox = ShellBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
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
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                let extra: [String: Any] = [
                    "stdout": shellBox.stdout,
                    "stderr": shellBox.stderr,
                    "code": shellBox.exitCode,
                    "timed_out": shellBox.timedOut,
                    "truncated": shellBox.truncated,
                ]
                writeResponse(fd, ok: true, image: result.imageBase64, extra: extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "file_get":
            guard let path = json["path"] as? String, !path.isEmpty else {
                writeResponse(fd, ok: false, error: "file_get requires path")
                return
            }
            // "save": write the bytes to a host-side path instead of inlining
            // base64 — the sane mode for large payloads like screen recordings.
            let savePath = json["save"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    box.data = try await ctl.downloadFile(path: path)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            guard result.ok, let fileData = box.data else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
                return
            }
            if let savePath {
                do {
                    try fileData.write(to: URL(fileURLWithPath: savePath))
                    writeResponse(fd, ok: true, path: savePath,
                                  extra: ["size": fileData.count])
                } catch {
                    writeResponse(fd, ok: false, error: "write \(savePath): \(error)")
                }
            } else {
                writeResponse(fd, ok: true, extra: [
                    "size": fileData.count,
                    "data": fileData.base64EncodedString(),
                ])
            }

        case "file_put":
            guard let path = json["path"] as? String, !path.isEmpty else {
                writeResponse(fd, ok: false, error: "file_put requires path")
                return
            }
            // Content comes either inline ("data_b64") or from a host-side
            // file ("load"); decode/read here on the client worker, off the
            // main actor.
            let payload: Data
            if let b64 = json["data_b64"] as? String {
                guard let decoded = Data(base64Encoded: b64) else {
                    writeResponse(fd, ok: false, error: "data_b64 is not valid base64")
                    return
                }
                payload = decoded
            } else if let loadPath = json["load"] as? String {
                guard let read = FileManager.default.contents(atPath: loadPath) else {
                    writeResponse(fd, ok: false, error: "cannot read host file: \(loadPath)")
                    return
                }
                payload = read
            } else {
                writeResponse(fd, ok: false, error: "file_put requires data_b64 or load")
                return
            }
            let perm = json["perm"] as? String ?? "644"
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.uploadFile(path: path, data: payload, permissions: perm)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, extra: ["size": payload.count])
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "app_launch":
            guard let bundleId = json["bundle_id"] as? String, !bundleId.isEmpty else {
                writeResponse(fd, ok: false, error: "app_launch requires bundle_id")
                return
            }
            let url = json["url"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let pid = try await ctl.appLaunch(bundleId: bundleId, url: url)
                    box.extra["pid"] = pid
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, image: result.imageBase64, extra: box.extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "app_terminate":
            guard let bundleId = json["bundle_id"] as? String, !bundleId.isEmpty else {
                writeResponse(fd, ok: false, error: "app_terminate requires bundle_id")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.appTerminate(bundleId: bundleId)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "app_list":
            let filter = json["filter"] as? String ?? "all"
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
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
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, extra: box.extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "app_foreground":
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
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
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, extra: box.extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "open_url":
            guard let url = json["url"] as? String, !url.isEmpty else {
                writeResponse(fd, ok: false, error: "open_url requires url")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.openURL(url)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "ipa_install":
            // Install an IPA already present on the guest filesystem, using
            // vphoned's built-in installer. The host streams nothing here — the
            // caller (e.g. autophone) has already placed the .ipa at `path` on
            // the guest, so we just relay the request over the control channel
            // and surface the guest's response verbatim.
            guard let path = json["path"] as? String, !path.isEmpty else {
                writeResponse(fd, ok: false, error: "ipa_install requires path")
                return
            }
            let registration = json["registration"] as? String ?? "User"
            let certPath = json["cert_path"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
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
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, extra: box.extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "camera_present":
            // Present a still image (QR/neutral) through the synthetic camera
            // under a fresh generation/role (§8.1). Fail-closed: ok=true only
            // once the two-level transport receipt (vphoned published +
            // libvcamcaptured observed) confirms the requested generation via
            // the guest 1337 vcam_status channel — a host publish alone is not
            // success (invariant #7).
            guard let path = json["path"] as? String, !path.isEmpty else {
                writeResponse(fd, ok: false, error: "camera_present requires path")
                return
            }
            guard let generation = json["generation"] as? String, !generation.isEmpty else {
                writeResponse(fd, ok: false, error: "camera_present requires generation")
                return
            }
            let role = json["role"] as? String ?? "qr"
            guard ["neutral", "qr", "test"].contains(role) else {
                writeResponse(fd, ok: false, error: "camera_present role must be neutral|qr|test")
                return
            }
            guard FileManager.default.fileExists(atPath: path) else {
                writeResponse(fd, ok: false, error: "camera_present path not found: \(path)")
                return
            }
            let fps = (json["fps"] as? Double) ?? (json["fps"] as? Int).map(Double.init) ?? 8.0

            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let cam = controller.cameraServer else {
                    result.error = "no camera server"
                    return
                }
                guard cam.present(imagePath: path, generation: generation, role: role, fps: fps) else {
                    result.error = "camera vsock not connected or image load failed"
                    return
                }
                // Assemble the two-level receipt from the guest. Until the guest
                // vcam_status handler lands, sendRequest errors → fail-closed.
                let receipt = await Self.cameraTransportReceipt(
                    controller: controller, generation: generation)
                box.extra["protocol_version"] = 2
                box.extra["source"] = "image"
                box.extra["role"] = role
                box.extra["generation"] = generation
                box.extra["streaming"] = true
                if let receipt {
                    box.extra["transport_receipt"] = receipt
                    result.ok = true
                } else {
                    result.error = "two-level transport receipt unavailable for \(generation)"
                }
            }
            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, extra: box.extra)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "camera_present failed",
                              extra: box.extra)
            }

        case "camera_status":
            guard let generation = json["generation"] as? String else {
                writeResponse(fd, ok: false, error: "camera_status requires generation")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            let box = ExtraBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let cam = controller.cameraServer else {
                    result.error = "no camera server"
                    return
                }
                box.extra = cam.hostStatus(generation: generation)
                if let receipt = await Self.cameraTransportReceipt(
                    controller: controller, generation: generation) {
                    box.extra["transport_receipt"] = receipt
                }
                result.ok = true
            }
            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: box.extra)

        case "camera_stop":
            guard let generation = json["generation"] as? String else {
                writeResponse(fd, ok: false, error: "camera_stop requires generation")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let cam = controller.cameraServer else {
                    result.error = "no camera server"
                    return
                }
                // A generation mismatch is a conflict, not a stop — never stop
                // another run's source (§8.4).
                if cam.stop(generation: generation) {
                    result.ok = true
                } else {
                    result.error = "generation \(generation) does not own the camera source"
                }
            }
            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "location_source_set", "location_stream_start", "location_stream_push",
             "location_source_control", "location_source_status", "location_source_stop":
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let provider = controller.locationProvider else {
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
                            throw SystemLocationControllerError(
                                code: "invalid_location_source",
                                message: "location_source_set mode must be fixed")
                        }
                        try Self.requireWGS84(json)
                        if json["persist"] as? Bool == true {
                            throw SystemLocationControllerError(
                                code: "invalid_location_source",
                                message: "persisted fixed sources are not implemented")
                        }
                        let owner = json["owner"] as? String ?? ""
                        let heartbeat = json["heartbeat_s"] as? Double ?? 1.0
                        let fix = try Self.systemLocationFix(json)
                        provider.beginExternalControl()
                        snapshot = try await systemController.setFixed(
                            owner: owner, fix: fix, heartbeatSeconds: heartbeat,
                            replace: json["replace"] as? Bool ?? false)
                    case "location_stream_start":
                        try Self.requireWGS84(json)
                        guard (json["on_timeout"] as? String ?? "hold") == "hold" else {
                            throw SystemLocationControllerError(
                                code: "invalid_location_source",
                                message: "on_timeout must be hold")
                        }
                        provider.beginExternalControl()
                        snapshot = try systemController.startStream(
                            owner: json["owner"] as? String ?? "",
                            watchdogSeconds: json["watchdog_s"] as? Double ?? 3.0,
                            replace: json["replace"] as? Bool ?? false)
                    case "location_stream_push":
                        let generation = json["generation"] as? String ?? ""
                        let fix = try Self.systemLocationFix(json)
                        snapshot = try await systemController.push(
                            generation: generation, fix: fix)
                    case "location_source_control":
                        guard let paused = json["paused"] as? Bool else {
                            throw SystemLocationControllerError(
                                code: "invalid_location_source",
                                message: "only paused control is currently supported")
                        }
                        snapshot = try await systemController.setPaused(
                            paused, generation: json["generation"] as? String ?? "")
                    case "location_source_status":
                        snapshot = systemController.snapshot()
                    case "location_source_stop":
                        snapshot = try await systemController.stop(
                            generation: json["generation"] as? String)
                    default:
                        preconditionFailure("unreachable location command")
                    }
                    result.ok = true
                    result.extra = snapshot
                } catch let error as SystemLocationControllerError {
                    result.code = error.code
                    result.error = error.message
                } catch {
                    result.code = "location_delivery_rejected"
                    result.error = error.localizedDescription
                }
            }
            semaphore.wait()
            var extra = result.extra
            if let code = result.code { extra["code"] = code }
            writeResponse(fd, ok: result.ok, error: result.error, extra: extra)

        case "location":
            // Push a simulated GPS fix into the guest's system-wide
            // CLSimulationManager (same channel the GUI location menu drives).
            // Fail-closed on the automation surface: reject out-of-range params,
            // require the guest to advertise the "location" capability, and wait
            // for the guest's ack (encode/disconnect/write/timeout all → ok:false).
            guard let lat = json["lat"] as? Double, let lon = json["lon"] as? Double else {
                writeResponse(fd, ok: false, error: "location requires lat and lon")
                return
            }
            let alt = json["alt"] as? Double ?? 0
            let hacc = json["hacc"] as? Double ?? 5
            let vacc = json["vacc"] as? Double ?? 5
            let speed = json["speed"] as? Double ?? 0
            let course = json["course"] as? Double ?? -1
            if let verr = Self.locationValidationError(
                lat: lat, lon: lon, alt: alt, hacc: hacc,
                vacc: vacc, speed: speed, course: course
            ) {
                writeResponse(fd, ok: false, error: verr)
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let provider = controller.locationProvider else {
                    result.error = "location provider unavailable"
                    return
                }
                // Take ownership of the guest location source: stop any Mac-location
                // forwarding or route replay so this fixed fix isn't overwritten by
                // the provider's next update (headless auto-forwards on connect; the
                // GUI menu may be syncing or replaying a route). Ownership persists
                // across guest reconnects until a GUI source is chosen again.
                provider.beginExternalControl()
                print("[location] deprecated host command 'location'; use location_source_set or stream")
                do {
                    _ = try await provider.systemLocationController.setFixed(
                        owner: "legacy-uds",
                        fix: SystemLocationFix(
                            producerSequence: 0,
                            latitude: lat, longitude: lon, altitude: alt,
                            horizontalAccuracy: hacc, verticalAccuracy: vacc,
                            speed: speed, course: course,
                            timestamp: Date().timeIntervalSince1970),
                        heartbeatSeconds: 1.0)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }
            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "location_stop":
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let provider = controller.locationProvider else {
                    result.error = "location provider unavailable"
                    return
                }
                // Silence the provider and hold ownership, else a live forwarder
                // or a reconnect would re-inject a fix right after we clear.
                provider.beginExternalControl()
                print("[location] deprecated host command 'location_stop'; use location_source_stop")
                do {
                    _ = try await provider.systemLocationController.clearLegacyLocation()
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }
            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        default:
            writeResponse(fd, ok: false, error: "unknown command: \(type)")
        }
    }

    /// Validate a simulated-location parameter set at the automation boundary.
    /// Returns an error message when the values could not produce a valid fix,
    /// or nil when they are acceptable. Kept pure (no I/O) so it is unit-testable
    /// and so the protocol edge rejects bad input before any guest round-trip.
    private nonisolated static func requireWGS84(_ json: [String: Any]) throws {
        guard (json["coordinate_system"] as? String)?.lowercased() == "wgs84" else {
            throw SystemLocationControllerError(
                code: "invalid_location_source",
                message: "coordinate_system must be wgs84")
        }
    }

    nonisolated static func systemLocationFix(
        _ json: [String: Any]
    ) throws -> SystemLocationFix {
        guard let sequence = json["producer_sequence"] as? Int,
              let lat = json["lat"] as? Double,
              let lon = json["lon"] as? Double
        else {
            throw SystemLocationControllerError(
                code: "invalid_location_source",
                message: "producer_sequence, lat and lon are required")
        }
        let timestamp: TimeInterval
        if let numeric = json["timestamp"] as? Double {
            timestamp = numeric
        } else if let text = json["timestamp"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let regular = ISO8601DateFormatter()
            guard let date = fractional.date(from: text) ?? regular.date(from: text) else {
                throw SystemLocationControllerError(
                    code: "invalid_location_source", message: "timestamp must be ISO-8601")
            }
            timestamp = date.timeIntervalSince1970
        } else {
            timestamp = 0
        }
        return SystemLocationFix(
            producerSequence: sequence,
            latitude: lat, longitude: lon,
            altitude: json["alt"] as? Double ?? 0,
            horizontalAccuracy: json["hacc"] as? Double ?? 5,
            verticalAccuracy: json["vacc"] as? Double ?? 5,
            speed: json["speed"] as? Double ?? 0,
            course: json["course"] as? Double ?? -1,
            timestamp: timestamp)
    }

    nonisolated static func locationValidationError(
        lat: Double, lon: Double, alt: Double,
        hacc: Double, vacc: Double, speed: Double, course: Double
    ) -> String? {
        for (name, value) in [
            ("lat", lat), ("lon", lon), ("alt", alt), ("hacc", hacc),
            ("vacc", vacc), ("speed", speed), ("course", course),
        ] where !value.isFinite {
            return "\(name) must be a finite number"
        }
        if lat < -90 || lat > 90 { return "lat out of range [-90, 90]: \(lat)" }
        if lon < -180 || lon > 180 { return "lon out of range [-180, 180]: \(lon)" }
        // Negative horizontalAccuracy marks the coordinate itself invalid — we are
        // asserting a real fix, so reject it. (vacc/speed may be negative: those are
        // CoreLocation "altitude/speed unknown" sentinels and stay permissive.)
        if hacc < 0 { return "hacc must be >= 0: \(hacc)" }
        // course: -1 is the CoreLocation "heading unknown" sentinel; otherwise [0, 360).
        if course != -1 && (course < 0 || course >= 360) {
            return "course must be -1 or in [0, 360): \(course)"
        }
        return nil
    }

    /// Query the guest 1337 `vcam_status` for one generation and return the
    /// composite receipt only when both the vphoned-published and
    /// libvcamcaptured-observed frame indices match. Returns nil (fail-closed)
    /// on any error, unsupported command, mismatch, or missing observe half.
    @MainActor
    private static func cameraTransportReceipt(
        controller: VPhoneHostControl, generation: String
    ) async -> [String: Any]? {
        guard let ctl = controller.control, ctl.isConnected else { return nil }
        // Give the guest a brief window to publish + observe the first frame.
        for _ in 0..<20 {
            guard let (resp, _) = try? await ctl.sendRequest(
                ["t": "vcam_status", "generation": generation])
            else { return nil }
            if let pub = resp["vphoned_published_frame_index"] as? Int,
               let obs = resp["libvcam_observed_frame_index"] as? Int,
               (resp["generation"] as? String) == generation,
               pub > 0, obs > 0 {
                return [
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

    // MARK: - Socket I/O

    private nonisolated static func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()

        while accumulated.count < 4096 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            accumulated.append(contentsOf: buffer[..<n])
            if accumulated.contains(0x0A) { break }
        }

        if let nlRange = accumulated.firstIndex(of: 0x0A) {
            return String(data: accumulated[..<nlRange], encoding: .utf8)
        }
        return accumulated.isEmpty ? nil : String(data: accumulated, encoding: .utf8)
    }

    private nonisolated static func writeResponse(
        _ fd: Int32, ok: Bool, path: String? = nil, error: String? = nil, image: String? = nil,
        extra: [String: Any]? = nil
    ) {
        var dict: [String: Any] = ["ok": ok]
        if let path { dict["path"] = path }
        if let error { dict["error"] = error }
        if let image { dict["image"] = image }
        if let extra { dict.merge(extra) { _, new in new } }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8)
        else { return }

        json += "\n"
        json.withCString { ptr in
            var remaining = strlen(ptr)
            var offset = 0
            while remaining > 0 {
                let written = write(fd, ptr.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
}
