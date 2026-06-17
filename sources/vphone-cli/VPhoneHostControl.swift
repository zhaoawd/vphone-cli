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
///   {"t":"app_foreground"}                      → frontmost app (bundle_id/name/pid)
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

    /// Thread-safe box for passing results between main actor and accept queue.
    private final class ResultBox: @unchecked Sendable {
        var path: String?
        var error: String?
        var ok = false
        var imageBase64: String?
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
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
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

        default:
            writeResponse(fd, ok: false, error: "unknown command: \(type)")
        }
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
