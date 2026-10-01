import AppKit
import SwiftUI

// MARK: - Theme

/// The project design system (CLAUDE.md): dark neutral background, system
/// monospace type, flat 1px borders, no custom shadows, status green, amber,
/// red and blue, 8/12/16 spacing.
enum VPhoneLaunchpadTheme {
    static let background = Color(hex: 0x1A1A1A)
    static let border = Color(hex: 0x333333)
    static let borderWidth: CGFloat = 1

    static let passed = Color(hex: 0x3FB950)
    static let warning = Color(hex: 0xD29922)
    static let failed = Color(hex: 0xF85149)
    static let running = Color(hex: 0x58A6FF)

    static let unit: CGFloat = 8
    static let padding: CGFloat = 12
    static let sectionGap: CGFloat = 16

    static var nsBackground: NSColor {
        NSColor(srgbRed: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// A self-drawn panel: 12pt padding inside a 1px border.
    func launchpadPanel() -> some View {
        padding(VPhoneLaunchpadTheme.padding)
            .overlay(Rectangle().strokeBorder(VPhoneLaunchpadTheme.border, lineWidth: VPhoneLaunchpadTheme.borderWidth))
    }
}
