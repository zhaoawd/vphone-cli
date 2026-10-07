import Foundation

@MainActor
struct VPhoneGuestShutdown {
    /// Acceptance is a request result. Only the VM delegate and stopper can
    /// confirm VM stop and disk release.
    enum Result: Equatable { case apiAccepted, classicAccepted, alreadyStopped, frameworkRequired }
    let api: (() async throws -> Bool)?
    let classic: () async -> Bool
    let running: () -> Bool

    func request() async -> Result {
        guard running() else { return .alreadyStopped }
        if let api, (try? await api()) == true { return .apiAccepted }
        guard running() else { return .alreadyStopped }
        if await classic() { return .classicAccepted }
        return running() ? .frameworkRequired : .alreadyStopped
    }
}
