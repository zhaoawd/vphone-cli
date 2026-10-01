import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Menu

/// The menu bar menu (upstream `VPhoneLaunchpadMenuBarMenu`, T26 B6): open
/// the window, start or stop a machine, quit. Every machine action goes
/// through `VPhoneLaunchpadMachineLibrary.performMenuBarAction`, under the
/// toolbar's `canStart`/`canStop` rules. The menu has no edit, create,
/// install, helper or panel entry.
struct VPhoneLaunchpadMenuBarMenu: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Launchpad") {
            VPhoneLaunchpadMainWindow.show(openWindow)
        }
        Divider()
        if case .failed = model.toolchain {
            Text("Embedded Toolchain Rejected")
        } else if model.machines.machines.isEmpty {
            Text("No Machines")
        }
        ForEach(model.machines.menuBarEntries) { entry in
            Menu {
                if let activity = entry.activity {
                    Text(verbatim: activity)
                }
                ForEach(entry.actions, id: \.self) { action in
                    button(action, entry)
                }
            } label: {
                Label {
                    Text(verbatim: entry.name)
                } icon: {
                    Image(systemName: entry.isRunning ? "circle.fill" : "circle")
                }
            }
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func button(_ action: VPhoneLaunchpadMenuBarEntry.Action, _ entry: VPhoneLaunchpadMenuBarEntry) -> some View {
        switch action {
        case .start: Button("Start") { perform(action, entry) }
        case .startHeadless: Button("Start Headless") { perform(action, entry) }
        case .stop: Button("Stop") { perform(action, entry) }
        }
    }

    private func perform(_ action: VPhoneLaunchpadMenuBarEntry.Action, _ entry: VPhoneLaunchpadMenuBarEntry) {
        let library = model.machines
        Task { await library.performMenuBarAction(action, on: entry.path) }
    }
}

// MARK: - Main window

enum VPhoneLaunchpadMainWindow {
    static let id = "main"

    /// Brings the Dock icon back, then opens (or fronts) the window.
    @MainActor
    static func show(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate()
    }

    /// The main window, when it is open: the titled window that is not a
    /// sheet. The status item and open menus are windows too.
    @MainActor
    static var window: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && $0.sheetParent == nil && ($0.isVisible || $0.isMiniaturized) }
    }
}

// MARK: - Dock icon

/// Shows the Dock icon while a window, minimised or not, or a menu is open,
/// and hides it otherwise (`VPhoneLaunchpadMenuBar.dockPresence`). Checked
/// once a second, in every run loop mode so it also runs while a menu is
/// tracking. With menu bar mode off the policy stays regular.
@MainActor
final class VPhoneLaunchpadDockPolicy {
    private var timer: Timer?
    private var menusOpen = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else {
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menusOpen += 1
                self?.update()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menusOpen = max(0, self.menusOpen - 1)
            }
        })
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update() {
        // Titled windows only: the status item and open menus are windows too.
        let hasWindow = NSApp.windows.contains { window in
            window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
        let presence = VPhoneLaunchpadMenuBar.dockPresence(
            menuBarEnabled: VPhoneLaunchpadMenuBar.isEnabled(), hasWindow: hasWindow, menusOpen: menusOpen)
        let policy: NSApplication.ActivationPolicy = presence == .regular ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Diagnostic line for the smoke check.
            FileHandle.standardOutput.write(Data("[launchpad] dock policy \(presence == .regular ? "regular" : "accessory")\n".utf8))
        }
    }
}
