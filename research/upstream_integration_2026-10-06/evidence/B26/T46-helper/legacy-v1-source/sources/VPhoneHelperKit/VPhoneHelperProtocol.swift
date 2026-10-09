import Foundation
import Security

public struct VPhoneHelperError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum VPhoneHelperIdentity {
    // Separate from the upstream Launchpad helper until the full operation set
    // is integrated. Never replace an upstream installation with this subset.
    public static let label = "com.vphone.cli.helper"
    public static let privilegedRight = label + ".privileged"
    public static let protocolVersion = "1"
    /// Bundle identifiers allowed to call the helper: the CLI app and the
    /// local Launchpad. Upstream `com.vphone.launchpad` is deliberately not
    /// among them; the local Launchpad uses its own identifier (T26).
    public static let clientIdentifiers = ["com.vphone.cli", "com.vphone.cli.launchpad"]
}

/// No command, shell, executable path, AMFI or legacy CFW verb is exposed.
@objc(VPhoneHelperProtocol)
public protocol VPhoneHelperProtocol {
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
    func installBundle(authorization: Data, version: String, archive: FileHandle, sha256: String,
                       reply: @escaping @Sendable (Data?, String?) -> Void)
    func verifyBundle(version: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}

public struct VPhoneHelperConfiguration: Sendable {
    public let team: String
    public var helperRequirement: String { Self.requirement(identifier: VPhoneHelperIdentity.label, team: team) }
    public var clientRequirements: [String] {
        VPhoneHelperIdentity.clientIdentifiers.map { Self.requirement(identifier: $0, team: team) }
    }
    public var connectionRequirement: String { clientRequirements.map { "(\($0))" }.joined(separator: " or ") }

    public init(team: String) throws {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw VPhoneHelperError("Helper signing team is not configured. Supply a valid 10-character Apple Team ID and matching signing identity.")
        }
        self.team = team
    }

    public static func fromHelperInfo(_ info: [String: Any]) throws -> Self {
        let configuration = try Self(team: info["VPhoneHelperSigningTeam"] as? String ?? "")
        guard info["CFBundleIdentifier"] as? String == VPhoneHelperIdentity.label,
              info["CFBundleVersion"] as? String == VPhoneHelperIdentity.protocolVersion,
              info["SMAuthorizedClients"] as? [String] == configuration.clientRequirements else {
            throw VPhoneHelperError("Helper metadata does not match the required client identities.")
        }
        return configuration
    }

    public static func fromClientInfo(_ info: [String: Any]) throws -> Self {
        let configuration = try Self(team: info["VPhoneHelperSigningTeam"] as? String ?? "")
        guard let requirements = info["SMPrivilegedExecutables"] as? [String: String],
              requirements[VPhoneHelperIdentity.label] == configuration.helperRequirement,
              VPhoneHelperIdentity.clientIdentifiers.contains(info["CFBundleIdentifier"] as? String ?? "") else {
            throw VPhoneHelperError("Client metadata does not pin the expected signed helper.")
        }
        return configuration
    }

    static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func verifyCode(_ url: URL, requirement: String) throws {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
                  | kSecCSCheckNestedCode | kSecCSSingleThreaded), required) == errSecSuccess else {
            throw VPhoneHelperError("Code does not satisfy the configured signing identity: \(url.path)")
        }
    }
}
