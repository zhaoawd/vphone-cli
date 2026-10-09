import SwiftUI

/// The frame every sheet shares (upstream `VPhoneLaunchpadSheet`): a title
/// over a rule, the content, and a rule over the buttons. A sheet's toolbar
/// shows no title, so the sheet draws its own head. B5 introduced the same
/// layout as `VPhoneLaunchpadPanelFrame`; B3 merges the two, so Host Setup,
/// Core Bundle, the console and the machine sheets share one frame with the
/// design system's background, monospace type and 1px rules.
struct VPhoneLaunchpadSheet<Content: View, Accessory: View, Actions: View>: View {
    let title: Text
    @ViewBuilder let content: Content
    /// Secondary buttons or status, on the leading side of the footer.
    @ViewBuilder let accessory: Accessory
    /// Cancel and confirm, or the closing button, on the trailing side.
    @ViewBuilder let actions: Actions

    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                title
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, VPhoneLaunchpadTheme.sectionGap)
            .padding(.vertical, VPhoneLaunchpadTheme.padding)

            rule

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            rule

            HStack(spacing: VPhoneLaunchpadTheme.unit) {
                accessory
                Spacer(minLength: VPhoneLaunchpadTheme.sectionGap)
                actions
            }
            .padding(.horizontal, VPhoneLaunchpadTheme.sectionGap)
            .padding(.vertical, VPhoneLaunchpadTheme.padding)
        }
        .background(VPhoneLaunchpadTheme.background)
        .fontDesign(.monospaced)
    }

    private var rule: some View {
        Rectangle()
            .fill(VPhoneLaunchpadTheme.border)
            .frame(height: VPhoneLaunchpadTheme.borderWidth)
    }
}

extension VPhoneLaunchpadSheet where Accessory == EmptyView {
    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(title, content: content, accessory: { EmptyView() }, actions: actions)
    }
}

/// The reason install and registration entries are disabled.
enum VPhoneLaunchpadDeferral {
    static var coreBundleInstall: String {
        String(localized: "Production Core Bundle installation is deferred (decision of 2026-09-30).")
    }

    static var helperRegistration: String {
        String(localized: "Helper registration is deferred (decision of 2026-09-30). Launchpad does not register or update the helper.")
    }
}
