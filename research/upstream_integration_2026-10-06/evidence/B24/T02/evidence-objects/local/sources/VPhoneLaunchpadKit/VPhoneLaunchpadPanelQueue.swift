import Foundation
import Observation

// MARK: - Panels

/// The sheets over the machine list that belong to no machine.
public enum VPhoneLaunchpadPanel: String, Identifiable, Sendable, CaseIterable {
    case hostSetup
    case coreBundle
    /// Recent Commands (B3), opened from the inspector.
    case commandHistory

    public var id: Self {
        self
    }
}

/// Which panel is on screen, and which one opens after it has closed.
///
/// Upstream `ded81cb`: on macOS, `sheet(item:onDismiss:)` calls `onDismiss`
/// in the same update that clears the item, while the sheet is still
/// attached. Setting the next panel there would swap its content into the
/// closing sheet. The next panel is set on the next turn of the main actor,
/// after the old sheet has gone.
@MainActor
@Observable
public final class VPhoneLaunchpadPanelQueue {
    /// The sheet's item binding.
    public var current: VPhoneLaunchpadPanel?
    public private(set) var queued: VPhoneLaunchpadPanel?
    /// The pending hand-off from `didDismiss()`; tests await it.
    @ObservationIgnored public private(set) var handoff: Task<Void, Never>?

    public init() {}

    /// Opens `next`. Another panel on screen closes first, so `next` arrives
    /// as a sheet of its own instead of replacing that sheet's content.
    public func present(_ next: VPhoneLaunchpadPanel) {
        guard let shown = current, shown != next else {
            current = next
            return
        }
        queued = next
        current = nil
    }

    /// The sheet's `onDismiss`. The queued panel is set on the next turn of
    /// the main actor, never in this update.
    public func didDismiss() {
        guard let next = queued else {
            return
        }
        queued = nil
        handoff = Task { [weak self] in
            self?.current = next
        }
    }
}
