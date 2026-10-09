import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - App

@main
struct VPhoneLaunchpadApp: App {
    @NSApplicationDelegateAdaptor(VPhoneLaunchpadAppDelegate.self) private var delegate
    @State private var model = VPhoneLaunchpadModel()
    /// Menu bar mode (B6), set in Host Setup. Off by default, as upstream.
    @AppStorage(VPhoneLaunchpadMenuBar.key) private var showsInMenuBar = false

    var body: some Scene {
        // A SwiftUI scene, not an NSWindowController-managed window, so
        // `isReleasedWhenClosed` does not apply here.
        Window(Text(verbatim: "vphone-launchpad"), id: VPhoneLaunchpadMainWindow.id) {
            VPhoneLaunchpadMainWindowContent(model: model, delegate: delegate)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra(isInserted: $showsInMenuBar) {
            VPhoneLaunchpadMenuBarMenu()
                .environment(model)
        } label: {
            Label {
                Text(verbatim: "vphone-launchpad")
            } icon: {
                Image(systemName: "iphone")
            }
        }
    }
}

/// The window's root view, which also hands the app delegate the model and
/// the scene's open-window action.
private struct VPhoneLaunchpadMainWindowContent: View {
    let model: VPhoneLaunchpadModel
    let delegate: VPhoneLaunchpadAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VPhoneLaunchpadRootView()
            .environment(model)
            .onAppear {
                delegate.model = model
                delegate.openWindow = openWindow
            }
    }
}

// MARK: - App delegate

/// Machines started with `vm launch` keep running when Launchpad quits
/// (B2). A `vm create` started here would keep running too, in its own
/// session, with nothing left to show its progress or stop it, so quitting
/// while one runs asks first; Quit sends SIGINT to each create's process
/// group (upstream `applicationShouldTerminate`). In menu bar mode (B6)
/// closing the window does not quit; otherwise it does.
@MainActor
final class VPhoneLaunchpadAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: VPhoneLaunchpadModel?
    /// The window scene's open action, kept for the smoke check's reopen.
    var openWindow: OpenWindowAction?
    private let dockPolicy = VPhoneLaunchpadDockPolicy()
    private var terminationPending = false

    func applicationWillFinishLaunching(_: Notification) {
        // The design system is dark only.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_: Notification) {
        dockPolicy.start()
        runSmokeWindowSteps()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        VPhoneLaunchpadMenuBar.terminatesAfterLastWindowClosed()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if let library = model?.machines,
           case let .confirm(machines) = VPhoneLaunchpadQuit.decision(library) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop Creating Machines?")
            alert.informativeText = String(localized: "vm create is running for \(machines.joined(separator: ", ")). Quitting sends SIGINT to its process group; the checkpoint then reads interrupted, and Resume continues from it later.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
            VPhoneLaunchpadQuit.confirmed(library)
        }
        guard let commandLine = model?.commandLine, commandLine.hasActiveCommands else {
            return .terminateNow
        }
        guard commandLine.beginTermination() else { return .terminateCancel }
        terminationPending = true
        Task { @MainActor in
            let result = await commandLine.waitForTermination()
            terminationPending = false
            switch result {
            case .drained:
                Self.diagnostic("quit: ordinary command output drained and logs closed")
                application.reply(toApplicationShouldTerminate: true)
            case .incomplete:
                Self.diagnostic("quit: ordinary command output incomplete; see command history")
                application.reply(toApplicationShouldTerminate: true)
            case .timedOut:
                Self.diagnostic("quit cancelled: command output did not drain within 5 seconds")
                application.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = String(localized: "Command Output Is Still Active")
                alert.informativeText = String(localized: "Quitting was cancelled because command output has not finished. The reader and log remain active. Wait for the command to finish, then quit again.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }
        }
        return .terminateLater
    }

    // MARK: - Smoke check

    /// For the UI smoke check, which sends no input events:
    /// `-VPhoneLaunchpadSmokeCloseWindow <seconds>` closes the main window
    /// that long after launch, as its close button would, and
    /// `-VPhoneLaunchpadSmokeReopenWindow <seconds>` then reopens it through
    /// the same call as the menu's Open Launchpad. Only the arguments domain
    /// is read, so nothing persists.
    private func runSmokeWindowSteps() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // `-VPhoneLaunchpadSmokeReportWindow <seconds>`: the main window's
        // width and content minimum, for the inspector width check.
        if let report = (arguments["VPhoneLaunchpadSmokeReportWindow"] as? String).flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(report))
                if let window = VPhoneLaunchpadMainWindow.window {
                    Self.diagnostic("smoke: main window content width \(Int(window.contentLayoutRect.width)), content minimum \(Int(window.contentMinSize.width))")
                }
            }
        }
        guard let close = (arguments["VPhoneLaunchpadSmokeCloseWindow"] as? String).flatMap(Double.init) else {
            return
        }
        let reopen = (arguments["VPhoneLaunchpadSmokeReopenWindow"] as? String).flatMap(Double.init)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(close))
            Self.diagnostic("smoke: closing the main window")
            VPhoneLaunchpadMainWindow.window?.close()
            guard let reopen else {
                return
            }
            try? await Task.sleep(for: .seconds(reopen))
            guard let openWindow = self?.openWindow else {
                Self.diagnostic("smoke: no open-window action")
                return
            }
            Self.diagnostic("smoke: reopening the main window")
            VPhoneLaunchpadMainWindow.show(openWindow)
        }
    }

    private static func diagnostic(_ text: String) {
        FileHandle.standardOutput.write(Data("[launchpad] \(text)\n".utf8))
    }
}
