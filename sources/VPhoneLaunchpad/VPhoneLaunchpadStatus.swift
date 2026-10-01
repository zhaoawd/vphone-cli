import SwiftUI

// MARK: - Status

enum VPhoneLaunchpadStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case pending
    case running
}

/// The state of a check or machine: an SF Symbol in its status colour, or a
/// small spinner while work is in flight. Every state occupies the same
/// square, so the symbol and the spinner do not push the text beside them
/// out of line.
struct VPhoneLaunchpadStatusIcon: View {
    let status: VPhoneLaunchpadStatus

    var body: some View {
        symbol
            .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .running:
            VPhoneLaunchpadSpinner()
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(VPhoneLaunchpadTheme.passed)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VPhoneLaunchpadTheme.warning)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(VPhoneLaunchpadTheme.failed)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

/// A spinner drawn by SwiftUI on every frame. The system one wraps an
/// NSProgressIndicator, which stops turning when a Form or Table row is
/// redrawn around it.
struct VPhoneLaunchpadSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(VPhoneLaunchpadTheme.running, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(2)
        }
        .accessibilityLabel(Text("In progress"))
    }
}
