import Foundation

// MARK: - Setting

/// Menu bar mode (upstream `VPhoneLaunchpadMenuBar`, T26 B6): closing the
/// window keeps Launchpad running in the menu bar, and the Dock icon follows
/// what is on screen. The app target owns the AppKit side
/// (`VPhoneLaunchpadDockPolicy`, the menu); the decisions live here so they
/// can be tested.
public enum VPhoneLaunchpadMenuBar {
    /// The upstream key, in Launchpad's own defaults domain
    /// (`com.vphone.cli.launchpad`).
    public static let key = "VPhoneLaunchpadShowsInMenuBar"

    /// The stored setting. A boolean, or the strings a launch argument
    /// (`-VPhoneLaunchpadShowsInMenuBar YES`) leaves in the arguments domain.
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        switch defaults.object(forKey: key) {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            ["yes", "true", "1"].contains(value.lowercased())
        default:
            false
        }
    }

    /// `applicationShouldTerminateAfterLastWindowClosed`: in menu bar mode
    /// the app stays behind in the menu bar.
    public static func terminatesAfterLastWindowClosed(_ defaults: UserDefaults = .standard) -> Bool {
        !isEnabled(defaults)
    }

    // MARK: - Dock icon

    /// The activation policy the Dock policy applies.
    public enum DockPresence: Equatable, Sendable {
        /// A Dock icon and an app menu.
        case regular
        /// No Dock icon; the menu bar item stays.
        case accessory
    }

    /// The Dock icon shows while a titled window (visible or minimised) or a
    /// menu is open, and always when menu bar mode is off.
    public static func dockPresence(menuBarEnabled: Bool, hasWindow: Bool, menusOpen: Int) -> DockPresence {
        guard menuBarEnabled else {
            return .regular
        }
        return hasWindow || menusOpen > 0 ? .regular : .accessory
    }
}

// MARK: - Menu entries

/// One machine in the menu bar menu. The menu offers only what the toolbar
/// already does for a machine: Start, Start Headless and Stop, under the
/// same `canStart`/`canStop` rules. No edit, create, install or panel entry
/// is reachable from the menu.
public struct VPhoneLaunchpadMenuBarEntry: Identifiable, Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case start
        case startHeadless
        case stop
    }

    public let path: VPhoneLaunchpadMachinePath
    public let isRunning: Bool
    public let actions: [Action]
    /// Shown in place of the actions: what Launchpad is doing to the machine
    /// (`Stopping…`, `Creating…`) or the busy operation the runtime record
    /// names.
    public let activity: String?

    public var id: VPhoneLaunchpadMachinePath {
        path
    }

    public var name: String {
        path.name
    }
}

public extension VPhoneLaunchpadMachineLibrary {
    /// The menu bar entries, in list order.
    var menuBarEntries: [VPhoneLaunchpadMenuBarEntry] {
        machines.map { machine in
            let path = machine.path
            let state = state(of: path)
            var actions: [VPhoneLaunchpadMenuBarEntry.Action] = []
            if canStart(path) {
                actions = [.start, .startHeadless]
            } else if canStop(path) {
                actions = [.stop]
            }
            var activity = activity(of: path)
            if activity == nil, case let .busy(operation) = state {
                activity = String(localized: "Busy: \(operation)")
            }
            return VPhoneLaunchpadMenuBarEntry(
                path: path, isRunning: state.isRunning, actions: actions, activity: activity)
        }
    }

    /// Runs a menu action through the same methods as the toolbar; each one
    /// checks `canStart`/`canStop` again.
    func performMenuBarAction(_ action: VPhoneLaunchpadMenuBarEntry.Action, on machine: VPhoneLaunchpadMachinePath) async {
        switch action {
        case .start:
            start(machine)
        case .startHeadless:
            start(machine, headless: true)
        case .stop:
            guard canStop(machine) else {
                return
            }
            await stop(machine)
        }
    }
}
