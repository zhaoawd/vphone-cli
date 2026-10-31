import Foundation

/// Finder can deliver documents before the embedded toolchain is verified.
/// Keep complete selections until the verified importer is attached.
@MainActor
public final class VPhoneLaunchpadArchiveOpenQueue {
    private var selections: [[URL]] = []
    private var importer: (@MainActor ([URL]) async -> Void)?
    private var draining = false
    public private(set) var error: VPhoneLaunchpadError?

    public init() {}

    @discardableResult
    public func enqueue(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }
        guard urls.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/")
            && !$0.path.contains("\0") && !$0.path.contains("\n")
            && ["tzst", "txz"].contains($0.pathExtension.lowercased()) }) else {
            error = VPhoneLaunchpadError(String(localized: "Unable to Import Archives"), detail: String(localized: "Choose local .tzst or .txz archives."))
            return false
        }
        selections.append(urls)
        drain()
        return true
    }

    public func attach(_ importer: @escaping @MainActor ([URL]) async -> Void) {
        guard self.importer == nil else { return }
        self.importer = importer
        drain()
    }

    private func drain() {
        guard let importer, !draining else { return }
        draining = true
        Task {
            defer { draining = false }
            while !selections.isEmpty {
                await importer(selections.removeFirst())
            }
        }
    }
}
