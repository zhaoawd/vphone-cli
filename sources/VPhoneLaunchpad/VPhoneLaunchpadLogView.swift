import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Log view

/// A log file shown read-only in an `NSTextView`.
///
/// The file is the only source. The view replays its tail when it appears
/// and follows it off the main actor while it stays on screen
/// (`VPhoneLaunchpadLogFollower`). No output passes through the app model, so
/// a chatty guest never invalidates a SwiftUI view. ANSI escapes are dropped;
/// the text cannot be edited.
struct VPhoneLaunchpadLogView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = VPhoneLaunchpadTheme.nsBackground
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.drawsBackground = true
            textView.backgroundColor = VPhoneLaunchpadTheme.nsBackground
            textView.textContainerInset = NSSize(width: VPhoneLaunchpadTheme.unit, height: VPhoneLaunchpadTheme.unit)
            textView.setAccessibilityIdentifier("launchpad-console-log")
            context.coordinator.textView = textView
        }
        context.coordinator.follow(url)
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.follow(url)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        /// Text kept in the view; older lines are dropped past this.
        static let maximumCharacters = 2_000_000
        static let pollInterval: Duration = .milliseconds(250)

        weak var textView: NSTextView?
        private var url: URL?
        private var task: Task<Void, Never>?

        private let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1),
        ]
        private let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        func follow(_ url: URL) {
            guard url != self.url else {
                return
            }
            self.url = url
            task?.cancel()
            clear()
            task = Task { [weak self] in
                var follower = VPhoneLaunchpadLogFollower(url: url)
                while !Task.isCancelled {
                    let (events, next) = await Task.detached { [follower] in
                        var follower = follower
                        let events = follower.poll()
                        return (events, follower)
                    }.value
                    follower = next
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    apply(events)
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        private func clear() {
            textView?.textStorage?.setAttributedString(NSAttributedString())
        }

        private func apply(_ events: [VPhoneLaunchpadLogFollower.Event]) {
            guard let textView, let storage = textView.textStorage else {
                return
            }
            for event in events {
                switch event {
                case .missing:
                    storage.setAttributedString(NSAttributedString(
                        string: String(localized: "No output yet.") + "\n", attributes: placeholderAttributes))
                case .reset:
                    storage.setAttributedString(NSAttributedString())
                case let .lines(lines):
                    let atBottom = isScrolledToBottom(textView)
                    storage.beginEditing()
                    storage.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: attributes))
                    if storage.length > Self.maximumCharacters {
                        // Drop whole lines from the start.
                        let excess = storage.length - Self.maximumCharacters
                        let text = storage.string as NSString
                        let cut = text.range(of: "\n", options: [], range: NSRange(location: excess, length: text.length - excess))
                        storage.deleteCharacters(in: NSRange(location: 0, length: cut.location == NSNotFound ? excess : cut.location + 1))
                    }
                    storage.endEditing()
                    if atBottom {
                        textView.scrollToEndOfDocument(nil)
                    }
                }
            }
        }

        private func isScrolledToBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else {
                return true
            }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= textView.bounds.height - 4
        }
    }
}
