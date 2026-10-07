/// Inspector values read from launchpad.json. A recorded origin does not
/// establish the executable or components currently running in a VM.
public struct VPhoneLaunchpadMachineOrigins: Equatable, Sendable {
    public let host: String
    public let guestEnvironment: String
    public let kernel: String
    public let bootChain: String
    public let runtime: String
    public let notice: String

    public init(_ read: VPhoneLaunchpadMachineBinding.Read) {
        runtime = "Unknown"
        switch read {
        case let .loaded(binding):
            host = binding.bundle
            guestEnvironment = binding.guestEnvironment ?? "Unknown"
            kernel = binding.kernel ?? "Unknown"
            bootChain = binding.bootChain ?? "Unknown"
            notice = "These are recorded origins; binding execution is pending integration. Actual runtime and applied component versions are unknown."
        case .missing:
            host = "Unknown"
            guestEnvironment = "Unknown"
            kernel = "Unknown"
            bootChain = "Unknown"
            notice = "launchpad.json is missing. No component origins are recorded."
        case let .invalid(reason):
            host = "Unknown"
            guestEnvironment = "Unknown"
            kernel = "Unknown"
            bootChain = "Unknown"
            notice = "Cannot read component origins: \(reason)"
        }
    }
}
