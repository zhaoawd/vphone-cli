import AppKit
import SwiftUI

// MARK: - Window minimum width

/// The width the machine list needs: its columns plus the open inspector
/// (`VPhoneLaunchpadMachinesView.Column`). The root view takes it as its
/// minimum width, which SwiftUI makes the window's content minimum.
struct VPhoneLaunchpadMinimumWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Widens the hosting window when its content is narrower than `width`.
///
/// A larger minimum alone left a window restored at 900 pt as it was, and
/// the list was laid out wider than the window, clipped on both sides (B6
/// smoke). This widens the window, within its screen, to `width`.
struct VPhoneLaunchpadWindowMinimumWidth: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context _: Context) -> FloorView {
        FloorView()
    }

    func updateNSView(_ view: FloorView, context _: Context) {
        view.width = width
        view.scheduleApply()
    }

    final class FloorView: NSView {
        var width: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        /// After the current layout pass, not inside it.
        func scheduleApply() {
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }

        private func apply() {
            guard let window, width > 0 else {
                return
            }
            let current = window.contentLayoutRect.width
            guard current < width else {
                return
            }
            var frame = window.frame
            frame.size.width += width - current
            if let visible = window.screen?.visibleFrame {
                frame.size.width = min(frame.width, visible.width)
                if frame.maxX > visible.maxX {
                    frame.origin.x = max(visible.minX, visible.maxX - frame.width)
                }
            }
            window.setFrame(frame, display: true)
        }
    }
}
