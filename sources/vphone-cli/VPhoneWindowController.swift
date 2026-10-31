import VPhoneCore
import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private var clipboardSync: VPhoneClipboardFocusSync?
    private var shortcutSync: VPhoneClipboardShortcutSync?
    private weak var control: VPhoneControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?

    private static func macClipboardPayload() -> VPhoneControl.ClipboardContent? {
        let board = NSPasteboard.general
        guard let kind = VPhoneClipboardTransfer.macKind(types: board.types?.map(\.rawValue) ?? []) else { return nil }
        switch kind {
        case .text:
            guard let text = board.string(forType: .string), VPhoneClipboardTransfer.fits(text: text) else { return nil }
            return .init(text: text, types: [], hasImage: false, changeCount: nil, imageData: nil)
        case let .image(type):
            guard let data = board.data(forType: .init(type)),
                  let representation = NSBitmapImageRep(data: data),
                  let png = representation.representation(using: .png, properties: [:]),
                  VPhoneClipboardTransfer.fits(image: png) else { return nil }
            return .init(text: nil, types: ["public.png"], hasImage: true, changeCount: nil, imageData: png)
        }
    }

    private nonisolated static let homeItemID = NSToolbarItem.Identifier("home")

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double,
        keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?, inputQueue: VPhoneHostInputQueue = VPhoneHostInputQueue()
    ) {
        self.control = control
        self.ecid = ecid
        let sync = VPhoneClipboardFocusSync(identity: { [weak control] in
            guard let control, let session = control.clipboardSession else { return nil }
            return .init(connection: session, revision: control.clipboardRevision)
        }, read: { [weak control] in
            guard let control else { throw CancellationError() }
            return try await control.clipboardGet()
        }, macChangeCount: { NSPasteboard.general.changeCount }, write: { [weak self] content in
            VPhoneClipboardMacWriter.write(content)
            self?.shortcutSync?.guestCopyWasWrittenToMac()
        })
        let shortcuts = VPhoneClipboardShortcutSync(identity: { [weak control] in
            guard let control, let connection = control.clipboardSession else { return nil }
            return .init(connection: connection, revision: control.clipboardRevision)
        }, macCount: { NSPasteboard.general.changeCount }, read: { [weak control] in
            guard let control else { throw CancellationError() }
            return try await control.clipboardGet()
        }, set: { [weak control] value in
            guard let control else { throw CancellationError() }
            if let text = value.text { try await control.clipboardSet(text: text) }
            else if let bytes = value.imageData { try await control.clipboardSet(imageData: bytes) }
        }, chord: { [weak control] usage in
            control?.sendHIDDown(page: 0x07, usage: 0xE3)
            control?.sendHIDPress(page: 0x07, usage: usage)
            control?.sendHIDUp(page: 0x07, usage: 0xE3)
        }, write: { value in
            VPhoneClipboardMacWriter.write(value)
            sync.clipboardMutated()
        })
        shortcutSync = shortcuts
        clipboardSync = sync
        control.onClipboardMutation = { [weak sync] in sync?.clipboardMutated() }

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        view.control = control
        view.onClipboardShortcut = { [weak self, weak control, weak shortcuts] key in
            guard let self, self.windowController?.window?.isKeyWindow == true,
                  let control, control.clipboardSession != nil, let shortcuts else { return false }
            let connection = control.clipboardSession
            let mac = NSPasteboard.general.changeCount
            let payload = key == "v" ? Self.macClipboardPayload() : nil
            if key == "v", payload == nil { return false }
            Task { @MainActor [weak self, weak control] in
                await inputQueue.run(cancelled: ()) {
                    guard self?.windowController?.window?.isKeyWindow == true,
                          control?.clipboardSession == connection,
                          NSPasteboard.general.changeCount == mac else { return }
                    if let payload { await shortcuts.paste(payload) }
                    else { await shortcuts.copy(cut: key == "x") }
                }
            }
            return true
        }
        virtualMachineView = view
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let windowSize = NSSize(
            width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentAspectRatio = windowSize
        window.title = "VPHONE [loading]"
        window.subtitle = makeSubtitle(ip: nil)
        window.contentView = vmView
        if let ecid {
            if !window.setFrameAutosaveName("vphone-\(ecid)") {
                window.center()
            }
        } else {
            window.center()
        }

        // Toolbar with unified style for two-line title
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        keyHelper.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for title indicator
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                self.clipboardSync?.connectionChanged()
                window.title = control.isConnected ? "VPHONE [connected]" : "VPHONE [disconnected]"
                window.subtitle = self.makeSubtitle(ip: control.isConnected ? control.guestIP : nil)
            }
        }
    }

    func windowDidBecomeKey(_: Notification) { clipboardSync?.focusChanged(key: true) }
    func windowDidResignKey(_: Notification) { shortcutSync?.invalidate(); clipboardSync?.focusChanged(key: false) }
    func windowWillClose(_: Notification) { shortcutSync?.invalidate(); clipboardSync?.stop() }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case let (ecid?, nil): ecid
        case let (nil, ip?): ip
        case (nil, nil): ""
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Home"
                item.toolTip = "Home Button"
                item.image = NSImage(
                    systemSymbolName: "circle.circle", accessibilityDescription: "Home"
                )
                item.target = self
                item.action = #selector(homePressed)
                return item
            }
            return nil
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.homeItemID]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.homeItemID, .flexibleSpace, .space]
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }
}
