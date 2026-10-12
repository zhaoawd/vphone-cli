import Foundation

/// Protocol binding for a single live host operation. These fields bind a
/// journal to a session; host plan authority is verified by the host scope.
enum EnvironmentOperation {
    static let capability = "environment_transaction_v2"
    static let hashes = ["plan_sha256", "desired_sha256", "executable_sha256", "daemon_sha256"]
    static let identifiers = ["operation", "generation", "daemon_instance", "vm_instance"]
    static func validate(_ value: Any?, daemon: String, instance: String) throws -> [String: String] {
        guard let context = value as? [String: String], context["mode"] == "regular-v2",
              hashes.allSatisfy({ key in context[key].map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } == true }),
              identifiers.allSatisfy({ key in context[key].flatMap(UUID.init(uuidString:)) != nil }),
              context["firmware_generation"].map({ !$0.isEmpty && !$0.contains("/") }) == true,
              context["bundle_version"].map({ !$0.isEmpty }) == true,
              context["daemon_sha256"] == daemon, context["daemon_instance"] == instance else {
            throw EnvironmentTransaction.Failure.invalid("Online operation requires a current regular/v2 session, generation and full source hashes")
        }
        return context
    }
}

/// Narrow exclusion at the guest boundary also covers independent API clients.
final class GuestMaintenanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    static let writers: Set<String> = ["environment.install", "environment.restore", "bootstrap.install", "bootstrap.uninstall", "bootstrap.firmware", "system.shutdown", "system.reboot", "system.respring", "agent.apply_update"]
    func run<T>(method: String, _ body: () throws -> T) throws -> T {
        guard Self.writers.contains(method) || method == "environment.status" else { return try body() }
        guard lock.try() else { throw EnvironmentTransaction.Failure.invalid("Guest maintenance operation is busy; inspect status after it converges") }
        defer { lock.unlock() }
        guard !stopped else { throw EnvironmentTransaction.Failure.invalid("Guest shutdown has sealed maintenance writes") }
        let result = try body()
        if ["system.shutdown", "system.reboot"].contains(method) { stopped = true }
        return result
    }
}
