import AppKit
import Foundation
import ImageIO
import Virtualization
import VPhoneCoreKit

// MARK: - Host Control Socket

/// Lightweight Unix domain socket server that accepts automation commands from
/// local processes (e.g. Claude Code via `nc -U`).  One JSON line in, one JSON
/// line out, then the connection closes.
///
/// Each connection is served on its own, so a slow request (a screenshot, a
/// long `rpc`) does not hold up other clients. Requests from different
/// clients may interleave; input events sent by one client stay in order.
///
/// The socket exists in both windowed and headless launches. With a window,
/// taps and swipes go through the VM view and the compact image is captured
/// from the display. Headless, taps and swipes go to vphoned's `input.touch`
/// and the image comes from the guest's `screen.screenshot`.
///
/// Every response includes an `"image"` field with a compact base64-encoded
/// color JPEG of the current screen (unless `"screen":false` is sent).
///
/// Supported commands:
///   {"t":"screenshot"}                          → full-res save to Desktop (or explicit path)
///   {"t":"screenshot","path":"/tmp/shot.png"}   → save to explicit path (PNG/JPEG by extension)
///   {"t":"tap","x":645,"y":1398}                → tap at pixel coordinates
///   {"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}  → swipe
///   {"t":"key","name":"home"}                   → hardware key (home/power/volup/voldown)
///   {"t":"key","name":"cmd+v"}                  → any other name goes to vphoned `input.key`
///   {"t":"hostkey","keys":"ctrl+space"}         → the same key events a Mac keyboard gives the VM
///                                                 window, through `VPhoneApplication` and the virtual
///                                                 keyboard (windowed launches only)
///   {"t":"type","text":"Hello"}                 → set guest clipboard
///   {"t":"ping"}                                → vphoned request/response
///   {"t":"rpc","method":"input.type","params":{"text":"ls\n"}}
///                                               → any vphoned method; its result is in `"result"`.
///                                                 When vphoned refuses it, `"error"` is the message
///                                                 and `"guest_error"` vphoned's whole error object
///                                                 (`code`, `message`, `results`, `reason`, `errno` …)
///   {"t":"push","local":"/abs/host/file","path":"/abs/guest/file","mode":"755"}
///                                               → streams a host file into the guest through vphoned's
///                                                 `PUT /v1/files/content`, any size. A `path` ending in `/`
///                                                 takes the host file's name; `mode` defaults to the host
///                                                 file's permissions. `"result"` has `path`, `local`, `size`
///   {"t":"pull","path":"/abs/guest/file","local":"/abs/host/file"}
///                                               → streams a guest file to the host; `local` may be a
///                                                 directory. The file replaces `local` only once complete
///   {"t":"network"}                             → the NIC's state, in `"result"`
///   {"t":"network","link":"down"}               → unplug (`up` replugs); not saved
///
/// All commands except "screenshot", "rpc", "push", "pull" and "network" wait
/// briefly then capture a compact screen image returned as
/// `"image":"<base64>"` in the response.
/// Pass `"screen":false` to skip the capture; "rpc" captures only when sent
/// `"screen":true`.
@MainActor
class VPhoneHostAutomationServer {
    private enum HostControlError: Error, CustomStringConvertible {
        case guestNotConnected
        case guestTouchUnavailable
        case inputGeometryUnavailable

        var description: String {
            switch self {
            case .guestNotConnected: "guest not connected"
            case .guestTouchUnavailable: "no VM window, and the guest does not support touch input"
            case .inputGeometryUnavailable: "the current input display geometry is unavailable"
            }
        }
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")
    private nonisolated static let clientQueue = DispatchQueue(
        label: "vphone.hostcontrol.client",
        attributes: .concurrent,
    )

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder = VPhoneScreenRecorder()
    private weak var control: VPhoneGuestControl?
    /// For the `network` command; nil until the VM exists.
    weak var virtualMachine: VPhoneVirtualMachine?

    /// Matches vphoned's JSON body limit, so an `rpc` line is never refused
    /// here that the guest would accept.
    private nonisolated static let maximumRequestLength = 1 << 20
    private nonisolated static let connections = DispatchSemaphore(value: 64)

    /// Screen pixel dimensions for coordinate mapping.
    private var screenWidth: Int = 1290
    private var screenHeight: Int = 2796

    /// Compact screenshot scale factor (1/3 = 430x932).
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// `captureView` is nil for a headless launch.
    func start(
        captureView: VPhoneVirtualMachineView?,
        screenRecorder: VPhoneScreenRecorder,
        control: VPhoneGuestControl,
        screenWidth: Int,
        screenHeight: Int,
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

        // A machine deep in the library (a template being built) has a path
        // longer than sun_path; it is bound through a short link to its folder.
        let bindResult: Int32? = VPhoneUnixSocket.withAddressablePath(socketPath) { path in
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                    for (i, byte) in pathBytes.enumerated() {
                        dst[i] = byte
                    }
                }
            }
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(fd, sockPtr, addrLen)
                }
            }
        }
        guard let bindResult else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard chmod(socketPath, 0o600) == 0 else {
            close(fd)
            return
        }
        guard listen(fd, SOMAXCONN) == 0 else {
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
            // Wake the blocked accept before a VM restart creates a new socket.
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Commands

    private func respond(to line: String) async -> Data {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String
        else {
            return Self.reply(ok: false, error: "invalid JSON")
        }

        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500

        do {
            switch type {
            case "capabilities":
                let connected = control?.isConnected == true
                let guest = Set(connected ? (control?.guestCapabilities ?? []) : [])
                let screen = connected && (windowedView != nil || guest.contains("screenshot"))
                let touch = connected && (windowedView != nil || guest.contains("touch"))
                let commands: [String: Bool] = [
                    "capabilities": true, "ping": connected, "rpc": connected, "screenshot": screen,
                    "tap": touch, "swipe": touch, "key": connected && guest.contains("hid"),
                    "type": connected && guest.contains("clipboard"),
                    "app_list": connected && guest.contains("apps"),
                    "app_foreground": connected && guest.contains("apps"),
                    "app_launch": connected && guest.contains("apps"),
                    "app_terminate": connected && guest.contains("apps"),
                    "file_get": connected && guest.contains("files"),
                    "file_put": connected && guest.contains("files"),
                    "shell": connected && guest.contains("shell_exec"),
                ]
                let object: [String: Any] = ["ok": true, "protocol": "upstream_v1",
                    "guest_connected": connected, "commands": commands,
                    "guest_capabilities": Array(guest).sorted(),
                    "headless": windowedView == nil,
                    "screen": ["width": screenWidth, "height": screenHeight, "scale": Self.compactScale],
                    "shell": ["single_stream_limit": 65536, "timeout_ms_max": 120000,
                              "available": commands["shell"] == true]]
                return try JSONSerialization.data(withJSONObject: object) + [0x0A]
            case "ping":
                try await connectedControl().sendPing()
                return Self.reply(ok: true)

            case "screenshot":
                let image = try await automationScreenshot()
                var outputPath: String?
                if json["save"] as? Bool != false {
                    let url = if let path = json["path"] as? String {
                        try screenRecorder.saveScreenshot(jpegData: image, to: URL(fileURLWithPath: path))
                    } else {
                        try screenRecorder.saveScreenshot(jpegData: image)
                    }
                    outputPath = url.path
                }
                // Always include compact image for screenshot command, from the same capture
                let compact = CGImageSourceCreateWithData(image as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                    .flatMap(compactJPEG)
                return Self.reply(ok: true, path: outputPath, image: compact)

            case "display.geometry":
                var result: [String: Any] = [
                    "configured_pixels": [screenWidth, screenHeight], "windowed": windowedView != nil,
                ]
                if let frame = await captureScreenImage() { result["capture_pixels"] = [frame.width, frame.height] }
                if let view = windowedView { result["view"] = view.inputGeometryReport() }
                if let geometry = try? await automationInputGeometry() {
                    let upright = geometry.screenshotSize
                    result["screenshot_pixels"] = [Double(upright.width), Double(upright.height)]
                    result["input_orientation"] = geometry.orientation.rawValue
                }
                return Self.reply(ok: true, result: result)

            case "tap":
                guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                    return Self.reply(ok: false, error: "tap requires x and y (pixel coordinates)")
                }
                try await tap(x: x, y: y)

            case "swipe":
                guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                      let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
                else {
                    return Self.reply(ok: false, error: "swipe requires x1, y1, x2, y2")
                }
                try await swipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: json["ms"] as? Int ?? 300)

            case "key":
                guard let name = json["name"] as? String else {
                    return Self.reply(
                        ok: false,
                        error: "key requires name (home/power/volup/voldown, or a keyboard key such as return or cmd+v)",
                    )
                }
                try await pressKey(name)

            case "hostkey":
                guard let keys = json["keys"] as? String else {
                    return Self.reply(ok: false, error: "hostkey requires keys, such as ctrl+space, fn, esc or vk:0x66")
                }
                guard let view = windowedView else {
                    return Self.reply(ok: false, error: "hostkey needs a VM window; this launch is headless")
                }
                try await VPhoneHostKeyEvents.press(keys, in: view)

            case "type":
                guard let text = json["text"] as? String else {
                    return Self.reply(ok: false, error: "type requires text")
                }
                try await connectedControl().clipboardSet(text: text)
                // Not a copy the user made, so leaving the window does not
                // put it on the Mac clipboard.
                captureView?.clipboardSync?.adoptGuestClipboard()

            case "rpc":
                guard let method = json["method"] as? String, !method.isEmpty else {
                    return Self.reply(ok: false, error: "rpc requires method (a vphoned method such as input.key)")
                }
                guard let params = (json["params"] ?? [String: Any]()) as? [String: Any] else {
                    return Self.reply(ok: false, error: "rpc params must be an object")
                }
                let result: [String: Any]
                do {
                    result = try await connectedControl().rpcAfterQueuedInput(method, params: params)
                } catch let failure as VPhoneGuestControl.GuestRPCFailure {
                    // `error` stays the message older clients read.
                    return Self.reply(ok: false, error: failure.message, guestError: failure.body)
                }
                let wantRPCScreen = json["screen"] as? Bool ?? false
                let image = wantRPCScreen ? await settledCompactScreenshot(delayMs: screenDelay) : nil
                return Self.reply(ok: true, image: image, result: result)

            case "push":
                guard let local = json["local"] as? String, local.hasPrefix("/"),
                      var path = json["path"] as? String, path.hasPrefix("/")
                else {
                    return Self.reply(ok: false, error: "push requires local (an absolute host path) and path (an absolute guest path)")
                }
                var status = stat()
                guard stat(local, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    return Self.reply(ok: false, error: "push: \(local) is not a readable regular file")
                }
                if path.hasSuffix("/") {
                    path += (local as NSString).lastPathComponent
                }
                // The host file's permissions unless the request names others,
                // so a pushed executable stays executable.
                let mode = json["mode"] as? String ?? String(status.st_mode & 0o777, radix: 8)
                let size = try await connectedControl().pushFile(
                    from: URL(fileURLWithPath: local), to: path, permissions: mode,
                )
                return Self.reply(ok: true, result: ["path": path, "local": local, "size": size])

            case "pull":
                guard let path = json["path"] as? String, path.hasPrefix("/"),
                      let local = json["local"] as? String, local.hasPrefix("/")
                else {
                    return Self.reply(ok: false, error: "pull requires path (an absolute guest path) and local (an absolute host path)")
                }
                var destination = URL(fileURLWithPath: local)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: local, isDirectory: &isDirectory), isDirectory.boolValue {
                    destination.appendPathComponent((path as NSString).lastPathComponent)
                }
                let size = try await connectedControl().pullFile(path, to: destination)
                return Self.reply(ok: true, result: ["path": path, "local": destination.path, "size": size])

            case "network":
                guard let virtualMachine else {
                    return Self.reply(ok: false, error: "the VM is not running")
                }
                if let link = json["link"] as? String {
                    guard link == "up" || link == "down" else {
                        return Self.reply(ok: false, error: "link must be up or down")
                    }
                    try virtualMachine.setNetworkLink(up: link == "up")
                }
                return Self.reply(ok: true, result: virtualMachine.networkStatus)

            default:
                return Self.reply(ok: false, error: "unknown command: \(type)")
            }
        } catch {
            return Self.reply(ok: false, error: "\(error)")
        }

        let image = wantScreen ? await settledCompactScreenshot(delayMs: screenDelay) : nil
        return Self.reply(ok: true, image: image)
    }

    private func connectedControl() throws -> VPhoneGuestControl {
        guard let control, control.isConnected else { throw HostControlError.guestNotConnected }
        return control
    }

    /// The VM view, when this launch has a window to inject events into.
    private var windowedView: VPhoneVirtualMachineView? {
        guard let captureView, captureView.window != nil else { return nil }
        return captureView
    }

    private func pressKey(_ name: String) async throws {
        let control = try connectedControl()
        let hidKey: (page: UInt32, usage: UInt32)? = switch name {
        case "home": (0x0C, 0x40)
        case "power": (0x0C, 0x30)
        case "side": (0x0C, 0x95) // An Apple Watch's side button.
        case "volup": (0x0C, 0xE9)
        case "voldown": (0x0C, 0xEA)
        default: nil
        }
        if let hidKey {
            control.sendHIDPress(page: hidKey.page, usage: hidKey.usage)
        } else {
            // vphoned's `input.key` owns keyboard names and
            // modifier combinations such as "cmd+v".
            _ = try await control.callAfterQueuedInput("input.key", params: ["name": name])
        }
    }

    // MARK: - Touch

    private func tap(x: Double, y: Double) async throws {
        let geometry = try await automationInputGeometry()
        let panelPoint = geometry.panelPoint(fromScreenshot: CGPoint(x: x, y: y))
        if let view = windowedView {
            view.injectTap(pixelX: panelPoint.x, pixelY: panelPoint.y, screenWidth: Int(geometry.panel.width), screenHeight: Int(geometry.panel.height))
            return
        }
        let control = try touchControl()
        let point = normalizedPoint(pixelX: panelPoint.x, pixelY: panelPoint.y, panel: geometry.panel)
        control.sendTouch(phase: 0, x: point.x, y: point.y)
        try? await Task.sleep(for: .milliseconds(80))
        control.sendTouch(phase: 3, x: point.x, y: point.y)
    }

    /// Returns once the swipe has finished, in either mode.
    private func swipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMs: Int) async throws {
        let geometry = try await automationInputGeometry()
        let first = geometry.panelPoint(fromScreenshot: CGPoint(x: x1, y: y1))
        let last = geometry.panelPoint(fromScreenshot: CGPoint(x: x2, y: y2))
        if let view = windowedView {
            view.injectSwipe(
                fromX: first.x,
                fromY: first.y,
                toX: last.x,
                toY: last.y,
                screenWidth: Int(geometry.panel.width),
                screenHeight: Int(geometry.panel.height),
                durationMs: durationMs,
            )
            try? await Task.sleep(for: .milliseconds(durationMs))
            return
        }
        let control = try touchControl()
        let start = normalizedPoint(pixelX: first.x, pixelY: first.y, panel: geometry.panel)
        let end = normalizedPoint(pixelX: last.x, pixelY: last.y, panel: geometry.panel)
        // Same step count and spacing as `injectSwipe`.
        let steps = max(10, durationMs / 16)
        let stepInterval = Double(durationMs) / Double(steps)

        control.sendTouch(phase: 0, x: start.x, y: start.y)
        for i in 1 ... steps {
            try? await Task.sleep(for: .milliseconds(stepInterval))
            let t = Double(i) / Double(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            control.sendTouch(phase: i < steps ? 1 : 3, x: x, y: y)
        }
    }

    /// Headless touches go through vphoned's `input.touch`.
    private func touchControl() throws -> VPhoneGuestControl {
        let control = try connectedControl()
        guard control.guestCapabilities.contains("touch") else { throw HostControlError.guestTouchUnavailable }
        return control
    }

    private func automationInputGeometry() async throws -> VPhoneDisplayViewport {
        let view = windowedView
        let panel = view?.recordingGraphicsDisplay?.sizeInPixels ?? CGSize(width: screenWidth, height: screenHeight)
        guard panel.width > 0, panel.height > 0 else { throw HostControlError.inputGeometryUnavailable }
        if let control, control.isConnected,
           let result = try? await control.rpcAfterQueuedInput("display.orientation"),
           let degrees = (result["degrees"] as? NSNumber)?.intValue,
           let orientation = VPhoneDisplayOrientation(degrees: degrees) {
            return VPhoneDisplayViewport(panel: panel, active: panel, orientation: orientation)!
        }
        // A native VM view can still receive input while vphoned starts.
        if let view { return VPhoneDisplayViewport(panel: panel, active: panel, orientation: view.displayedOrientation)! }
        throw HostControlError.inputGeometryUnavailable
    }

    private func automationScreenshot() async throws -> Data {
        let before = try await automationInputGeometry()
        let jpeg = try await connectedControl().screenshotJPEG()
        let after = try await automationInputGeometry()
        guard before == after else { throw HostControlError.inputGeometryUnavailable }
        guard before.active != before.panel else { return jpeg }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HostControlError.inputGeometryUnavailable
        }
        let expected = before.orientation.displayedSize(panel: before.panel)
        guard full.width == Int(expected.width), full.height == Int(expected.height),
              let cropped = full.cropping(to: before.screenshotCrop),
              let result = NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 1])
        else { throw HostControlError.inputGeometryUnavailable }
        return result
    }

    /// Fixed-panel pixels to the 0...1 range `input.touch` takes.
    private func normalizedPoint(pixelX: Double, pixelY: Double, panel: CGSize) -> (x: Double, y: Double) {
        (
            max(0, min(1, pixelX / Double(panel.width))),
            max(0, min(1, pixelY / Double(panel.height))),
        )
    }

    // MARK: - Compact Screenshot

    private func settledCompactScreenshot(delayMs: Int) async -> String? {
        try? await Task.sleep(for: .milliseconds(delayMs))
        return await captureCompactScreenshot()
    }

    /// Capture current screen as a small color JPEG, returned as base64.
    private func captureCompactScreenshot() async -> String? {
        guard let cgImage = await captureScreenImage() else { return nil }
        return compactJPEG(cgImage)
    }

    private func compactJPEG(_ cgImage: CGImage) -> String? {
        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        // Draw into an sRGB context; JPEG has no alpha, so none is kept
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: dstW,
                  height: dstH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
              )
        else { return nil }

        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let scaledImage = ctx.makeImage() else { return nil }

        // Encode as low-quality JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.35]
        CGImageDestinationAddImage(dest, scaledImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// The display capture with a window; the guest's own screenshot headless.
    private func captureScreenImage() async -> CGImage? {
        if let view = windowedView {
            return try? await screenRecorder.captureStillImage(from: view)
        }
        guard let control, control.isConnected,
              let jpeg = try? await control.screenshotJPEG(),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(listenFD: Int32, controller: VPhoneHostAutomationServer?) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                // A client that gives up before accept must not end the loop.
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                break
            }
            guard fcntl(clientFD, F_SETNOSIGPIPE, 1) != -1 else {
                close(clientFD)
                continue
            }
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            guard setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0,
                setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size)) == 0
            else {
                close(clientFD)
                continue
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(clientFD, &uid, &gid) == 0, uid == geteuid(),
                  connections.wait(timeout: .now()) == .success else {
                close(clientFD)
                continue
            }
            clientQueue.async {
                serveClient(clientFD, controller: controller)
            }
        }
    }

    /// Socket reads and writes block, so they stay on `clientQueue`; only the
    /// command itself runs on the main actor, where it awaits without
    /// holding a thread.
    private final class ClientState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        func disconnected() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            if finished { return nil }
            var byte: UInt8 = 0
            let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || count > 0 { return true }
            return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
        }
    }

    private nonisolated static func serveClient(_ fd: Int32, controller: VPhoneHostAutomationServer?) {
        guard let (line, typedAhead) = readCommand(from: fd) else {
            close(fd); connections.signal(); return
        }
        if let request = shellRequest(in: line) {
            relayShell(fd, request: request, typedAhead: typedAhead, controller: controller)
            connections.signal()
            return
        }
        guard typedAhead.isEmpty else {
            write(reply(ok: false, error: "one request per connection"), to: fd)
            close(fd); connections.signal(); return
        }
        var command = line
        var shellID: String?
        if let data = line.data(using: .utf8),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["t"] as? String == "rpc", object["method"] as? String == "shell.exec" {
            shellID = UUID().uuidString
            var params = object["params"] as? [String: Any] ?? [:]
            params["request_id"] = shellID
            object["params"] = params
            if let wire = try? JSONSerialization.data(withJSONObject: object), wire.count < maximumRequestLength {
                command = String(decoding: wire, as: UTF8.self)
            } else {
                write(reply(ok: false, error: "shell.exec request exceeds 1 MiB"), to: fd)
                close(fd); connections.signal(); return
            }
        }
        let state = ClientState(fd)
        if let shellID {
            clientQueue.async {
                while let disconnected = state.disconnected() {
                    if disconnected {
                        Task { @MainActor in
                            _ = try? await controller?.control?.rpcAfterQueuedInput("shell.cancel", params: ["request_id": shellID])
                        }
                        break
                    }
                    usleep(25000)
                }
            }
        }
        let admittedCommand = command
        Task { @MainActor in
            let response = await controller?.respond(to: admittedCommand)
                ?? reply(ok: false, error: "host control stopped")
            clientQueue.async {
                state.finish()
                write(response, to: fd)
                close(fd)
                connections.signal()
            }
        }
    }

    // MARK: - Socket I/O

    /// The command line, and whatever arrived behind it. Only a shell has
    /// anything behind it: its client starts typing without waiting for a
    /// reply, and those keystrokes are already the session's input.
    private nonisolated static func readCommand(from fd: Int32) -> (line: String, rest: Data)? {
        VPhoneHostAutomationIO.readCommand(from: fd)
    }

    // MARK: - Interactive Shell

    /// The parsed command when it is `{"t":"shell"}`, or nil for everything
    /// else, which the one-line protocol answers as it always has.
    private nonisolated static func shellRequest(in line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["t"] as? String == "shell"
        else { return nil }
        return json
    }

    /// `{"t":"shell"}` hands the connection to the guest's terminal: every
    /// byte after the command line is input, everything the session writes
    /// comes back, and one JSON line at the end says how it finished. So
    /// `nc -U .../vphone.sock` is a shell in the guest, and the terminal
    /// window opens the same route.
    ///
    /// `program` picks what runs (unset for vphoned's own JavaScript session,
    /// a bare name from the bootstrap, or an absolute path); `cols` and `rows`
    /// set the initial terminal size.
    private nonisolated static func relayShell(
        _ fd: Int32,
        request: [String: Any],
        typedAhead: Data,
        controller: VPhoneHostAutomationServer?,
    ) {
        // A terminal with nobody typing at it is the normal state, so the
        // read timeout the line protocol wants would end a healthy session.
        // The send timeout stays: a client that stops reading must not hold
        // the session's output thread for good.
        var none = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        var send = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))

        let relay = VPhoneHostShellRelay(descriptor: fd)
        let options = VPhoneGuestShellChannel.Options(
            program: request["program"] as? String,
            columns: (request["cols"] as? NSNumber)?.intValue ?? 80,
            rows: (request["rows"] as? NSNumber)?.intValue ?? 24,
        )
        Task { @MainActor in
            do {
                guard let controller else { throw HostControlError.guestNotConnected }
                let channel = try await VPhoneGuestShellChannel.open(
                    control: try controller.connectedControl(),
                    options: options,
                    onOutput: { relay.deliver($0) },
                    onEnd: { relay.end($0) },
                )
                relay.attach(channel, typedAhead: typedAhead)
            } catch {
                relay.refuse(String(describing: error))
            }
        }
    }

    /// One JSON line, ready to write.
    private nonisolated static func reply(
        ok: Bool,
        path: String? = nil,
        error: String? = nil,
        image: String? = nil,
        result: [String: Any]? = nil,
        guestError: [String: Any]? = nil,
    ) -> Data {
        var dict: [String: Any] = ["ok": ok]
        if let result {
            dict["result"] = result
        }
        if let guestError {
            dict["guest_error"] = guestError
        }
        if let path {
            dict["path"] = path
        }
        if let error {
            dict["error"] = error
        }
        if let image {
            dict["image"] = image
        }

        guard var data = try? JSONSerialization.data(withJSONObject: dict) else {
            return Data(#"{"ok":false,"error":"response is not JSON"}"#.utf8) + [0x0A]
        }
        data.append(0x0A)
        return data
    }

    private nonisolated static func write(_ data: Data, to fd: Int32) {
        VPhoneHostAutomationIO.write(data, to: fd)
    }
}
