import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - App

@main
struct VPhoneLaunchpadApp: App {
    @NSApplicationDelegateAdaptor(VPhoneLaunchpadAppDelegate.self) private var delegate
    @State private var model = VPhoneLaunchpadModel()

    var body: some Scene {
        // A SwiftUI scene, not an NSWindowController-managed window, so
        // `isReleasedWhenClosed` does not apply here.
        Window(Text(verbatim: "vphone-launchpad"), id: "main") {
            VPhoneLaunchpadRootView()
                .environment(model)
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - App delegate

/// Machines started with `vm launch` keep running when Launchpad quits
/// (B2). A `vm create` started here would keep running too, in its own
/// session, with nothing left to show its progress or stop it, so quitting
/// while one runs asks first; Quit sends SIGINT to each create's process
/// group (upstream `applicationShouldTerminate`). There is no menu bar mode
/// yet (B6), so closing the window quits.
@MainActor
final class VPhoneLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPhoneLaunchpadModel?

    func applicationWillFinishLaunching(_: Notification) {
        // The design system is dark only.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let library = model?.machines,
              case let .confirm(machines) = VPhoneLaunchpadQuit.decision(library)
        else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop Creating Machines?")
        alert.informativeText = String(localized: "vm create is running for \(machines.joined(separator: ", ")). Quitting sends SIGINT to its process group; the checkpoint then reads interrupted, and Resume continues from it later.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        VPhoneLaunchpadQuit.confirmed(library)
        return .terminateNow
    }
}
