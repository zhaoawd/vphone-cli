import AppKit
import Dynamic
import Foundation
import Virtualization

class VPhoneVirtualMachineView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?
    weak var control: VPhoneControl?

    private var touchRoute = VPhoneTouchRoute()
    private var currentTouchSwipeAim: Int = 0
    private var isDragHighlightVisible = false

    // MARK: - Touch Event Log (opt-in)

    /// Set `VPHONE_TOUCH_LOG=1` to trace injected gestures and the route each
    /// resulting touch phase takes. Read once; disabled means no per-event work.
    private static let touchLogEnabled = ProcessInfo.processInfo.environment["VPHONE_TOUCH_LOG"] == "1"

    @MainActor private static var nextGestureID = 0

    /// Identifies the injected gesture whose synthesized events are currently
    /// being delivered, so the route log can be correlated with the injection log.
    private var loggingGestureID: Int?

    @MainActor private static func allocateGestureID() -> Int {
        nextGestureID += 1
        return nextGestureID
    }

    private static func touchLogTime() -> String {
        String(format: "%.4f", ProcessInfo.processInfo.systemUptime)
    }

    private static func touchLogCoord(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// One injected event: `[touchlog] t=… gid=… src=inject …`
    private static func logInjectEvent(
        gestureID: Int,
        gesture: String,
        kind: String,
        step: Int,
        steps: Int,
        pixel: NSPoint,
        windowPoint: NSPoint
    ) {
        guard touchLogEnabled else { return }
        print(
            "[touchlog] t=\(touchLogTime()) gid=\(gestureID) src=inject gesture=\(gesture) kind=\(kind)"
                + " step=\(step) steps=\(steps)"
                + " px=\(touchLogCoord(pixel.x)) py=\(touchLogCoord(pixel.y))"
                + " wx=\(touchLogCoord(windowPoint.x)) wy=\(touchLogCoord(windowPoint.y))"
        )
    }

    /// One routed touch phase: `[touchlog] t=… gid=… src=route …`
    private func logRouteEvent(phase: Int, normalizedPoint: CGPoint, destination: VPhoneTouchRoute.Destination) {
        guard Self.touchLogEnabled else { return }
        let route: String
        let session: String
        switch destination {
        case .native:
            route = "native"
            session = "-"
        case let .guest(value):
            route = "guest"
            session = "\(value)"
        case .discard:
            route = "discard"
            session = "-"
        }
        let gid = loggingGestureID.map(String.init) ?? "-"
        print(
            "[touchlog] t=\(Self.touchLogTime()) gid=\(gid) src=route phase=\(phase) route=\(route)"
                + " session=\(session) edge=\(currentTouchSwipeAim)"
                + " nx=\(String(format: "%.5f", normalizedPoint.x)) ny=\(String(format: "%.5f", normalizedPoint.y))"
        )
    }

    /// Tag the synthesized events of one injected gesture with its id.
    private func withLoggedGesture(_ gestureID: Int, _ body: () -> Void) {
        guard Self.touchLogEnabled else {
            body()
            return
        }
        let previous = loggingGestureID
        loggingGestureID = gestureID
        body()
        loggingGestureID = previous
    }

    // MARK: - Private API Accessors

    /// https://github.com/wh1te4ever/super-tart-vphone-writeup/blob/main/contents/ScreenSharingVNC.swift
    private var multiTouchDevice: AnyObject? {
        guard let vm = virtualMachine else { return nil }
        guard let devices = Dynamic(vm)._multiTouchDevices.asObject as? NSArray,
              devices.count > 0
        else {
            return nil
        }
        return devices.object(at: 0) as AnyObject
    }

    var recordingGraphicsDisplay: VZGraphicsDisplay? {
        if let display = Dynamic(self)._graphicsDisplay.asObject as? VZGraphicsDisplay {
            return display
        }
        return virtualMachine?.graphicsDevices.first?.displays.first
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure keyboard events route to VM view right after window attach.
        window?.makeFirstResponder(self)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the VM display should always restore keyboard focus.
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        currentTouchSwipeAim = hitTestEdge(at: localPoint)
        if sendTouchEvent(phase: 0, localPoint: localPoint, timestamp: event.timestamp) { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if sendTouchEvent(phase: 1, localPoint: localPoint, timestamp: event.timestamp) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if !sendTouchEvent(phase: 3, localPoint: localPoint, timestamp: event.timestamp) {
            super.mouseUp(with: event)
        }
        currentTouchSwipeAim = 0
    }

    override func rightMouseDown(with _: NSEvent) {
        guard let keyHelper else { return }
        keyHelper.sendHome()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "h"
        {
            keyHelper?.sendHome()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Drag and Drop Install

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard droppedInstallPackageURL(from: sender) != nil else { return [] }
        updateDragHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        updateDragHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppedInstallPackageURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        updateDragHighlight(false)
        guard let url = droppedInstallPackageURL(from: sender) else { return false }

        Task { @MainActor in
            guard let control else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }
            guard control.isConnected else {
                showAlert(title: "Install App Package", message: "Guest is not connected.", style: .warning)
                return
            }

            do {
                let result = try await control.installIPA(localURL: url)
                print("[install] \(result)")
                showAlert(
                    title: "Install App Package",
                    message: VPhoneInstallPackage.successMessage(
                        for: url.lastPathComponent,
                        detail: result
                    ),
                    style: .informational
                )
            } catch {
                showAlert(title: "Install App Package", message: "\(error)", style: .warning)
            }
        }
        return true
    }

    private func droppedInstallPackageURL(from sender: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first(where: VPhoneInstallPackage.isSupportedFile)
    }

    private func updateDragHighlight(_ visible: Bool) {
        guard isDragHighlightVisible != visible else { return }
        isDragHighlightVisible = visible
        wantsLayer = true
        layer?.borderWidth = visible ? 4 : 0
        layer?.borderColor = visible ? NSColor.systemGreen.cgColor : NSColor.clear.cgColor
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Programmatic Touch (for automation)

    /// Convert screenshot pixel coordinates to NSView local coordinates.
    private func pixelToLocal(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) -> NSPoint {
        let w = bounds.width
        let h = bounds.height
        let localX = pixelX / Double(screenWidth) * w
        // Screenshot y=0 is top, NSView y=0 is bottom (non-flipped)
        let localY = (1.0 - pixelY / Double(screenHeight)) * h
        return NSPoint(x: localX, y: localY)
    }

    /// Synthesize an NSEvent at a given window point.
    private func synthesizeMouseEvent(type: NSEvent.EventType, at windowPoint: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseUp ? 0 : 1,
            pressure: type == .leftMouseUp ? 0.0 : 1.0
        )
    }

    /// Inject a tap at pixel coordinates (matching screenshot image dimensions).
    func injectTap(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) {
        let localPoint = pixelToLocal(pixelX: pixelX, pixelY: pixelY, screenWidth: screenWidth, screenHeight: screenHeight)
        let windowPoint = convert(localPoint, to: nil)
        let gestureID = Self.touchLogEnabled ? Self.allocateGestureID() : 0
        let pixel = NSPoint(x: pixelX, y: pixelY)

        Self.logInjectEvent(
            gestureID: gestureID, gesture: "tap", kind: "down", step: 0, steps: 0,
            pixel: pixel, windowPoint: windowPoint
        )
        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: windowPoint) {
            withLoggedGesture(gestureID) { mouseDown(with: downEvent) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            Self.logInjectEvent(
                gestureID: gestureID, gesture: "tap", kind: "up", step: 0, steps: 0,
                pixel: pixel, windowPoint: windowPoint
            )
            if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: windowPoint) {
                self.withLoggedGesture(gestureID) { self.mouseUp(with: upEvent) }
            }
        }
    }

    /// Inject a swipe from one pixel coordinate to another.
    func injectSwipe(
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        screenWidth: Int, screenHeight: Int, durationMs: Int = 300
    ) {
        let startLocal = pixelToLocal(pixelX: fromX, pixelY: fromY, screenWidth: screenWidth, screenHeight: screenHeight)
        let endLocal = pixelToLocal(pixelX: toX, pixelY: toY, screenWidth: screenWidth, screenHeight: screenHeight)
        let startWindow = convert(startLocal, to: nil)
        let endWindow = convert(endLocal, to: nil)

        let steps = max(10, durationMs / 16)
        let stepInterval = Double(durationMs) / Double(steps) / 1000.0
        let gestureID = Self.touchLogEnabled ? Self.allocateGestureID() : 0

        Self.logInjectEvent(
            gestureID: gestureID, gesture: "swipe", kind: "down", step: 0, steps: steps,
            pixel: NSPoint(x: fromX, y: fromY), windowPoint: startWindow
        )
        if let downEvent = synthesizeMouseEvent(type: .leftMouseDown, at: startWindow) {
            withLoggedGesture(gestureID) { mouseDown(with: downEvent) }
        }

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = startWindow.x + (endWindow.x - startWindow.x) * t
            let y = startWindow.y + (endWindow.y - startWindow.y) * t
            let pt = NSPoint(x: x, y: y)
            let pixel = NSPoint(x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
            let delay = stepInterval * Double(i)

            if i < steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    Self.logInjectEvent(
                        gestureID: gestureID, gesture: "swipe", kind: "drag", step: i, steps: steps,
                        pixel: pixel, windowPoint: pt
                    )
                    if let dragEvent = self.synthesizeMouseEvent(type: .leftMouseDragged, at: pt) {
                        self.withLoggedGesture(gestureID) { self.mouseDragged(with: dragEvent) }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    Self.logInjectEvent(
                        gestureID: gestureID, gesture: "swipe", kind: "up", step: i, steps: steps,
                        pixel: pixel, windowPoint: pt
                    )
                    if let upEvent = self.synthesizeMouseEvent(type: .leftMouseUp, at: pt) {
                        self.withLoggedGesture(gestureID) { self.mouseUp(with: upEvent) }
                    }
                }
            }
        }
    }

    // MARK: - Legacy Touch Injection (macOS 15)

    @discardableResult
    private func sendTouchEvent(phase: Int, localPoint: NSPoint, timestamp: TimeInterval) -> Bool {
        let normalizedPoint = normalizeCoordinate(localPoint)

        // Prefer vphoned's guest-side HID path when available. This avoids
        // relying on private VZ touch delivery after the guest is connected.
        let destination = touchRoute.destination(phase: phase, guestSession: control?.touchSession)
        logRouteEvent(phase: phase, normalizedPoint: normalizedPoint, destination: destination)

        switch destination {
        case .guest:
            control?.sendTouch(phase: phase, x: Double(normalizedPoint.x), y: Double(normalizedPoint.y),
                               fromEdge: currentTouchSwipeAim != 0)
            return true
        case .discard:
            // The guest releases the touch when its session ends. Do not send
            // an orphan move/up through VZ or into a replacement connection.
            return true
        case .native:
            break
        }

        guard let device = multiTouchDevice,
              virtualMachine != nil
        else { return false }

        let touch = Dynamic._VZTouch(
            view: self,
            index: 0,
            phase: phase,
            location: normalizedPoint,
            swipeAim: currentTouchSwipeAim,
            timestamp: timestamp
        )

        guard let touchObj = touch.asObject else {
            print("[vphone] Error: Failed to create _VZTouch")
            return false
        }

        let touchEvent = Dynamic._VZMultiTouchEvent(touches: [touchObj])
        guard let eventObj = touchEvent.asObject else { return false }

        Dynamic(device).sendMultiTouchEvents([eventObj] as NSArray)
        return true
    }

    // MARK: - Coordinate Helpers

    private func normalizeCoordinate(_ localPoint: NSPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height

        guard w > 0, h > 0 else { return .zero }

        var nx = Double(localPoint.x / w)
        var ny = Double(localPoint.y / h)

        // Clamp
        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

        if !isFlipped {
            ny = 1.0 - ny
        }

        return CGPoint(x: nx, y: ny)
    }

    private func hitTestEdge(at point: CGPoint) -> Int {
        let w = bounds.width
        let h = bounds.height

        let edgeThreshold: CGFloat = 32.0

        let distLeft = point.x
        let distRight = w - point.x
        let distTop = isFlipped ? point.y : (h - point.y)
        let distBottom = isFlipped ? (h - point.y) : point.y

        var minDist = distLeft
        var edgeCode = 8 // Left

        if distRight < minDist {
            minDist = distRight
            edgeCode = 4 // Right
        }

        if distBottom < minDist {
            minDist = distBottom
            edgeCode = 2 // Bottom (Home bar swipe up)
        }

        if distTop < minDist {
            minDist = distTop
            edgeCode = 1 // Top (Notification Center)
        }

        return minDist < edgeThreshold ? edgeCode : 0
    }
}
