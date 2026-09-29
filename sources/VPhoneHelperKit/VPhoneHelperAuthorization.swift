import Darwin
import Foundation
import Security

/// Adapted from upstream 2.0.8. The daemon installs the rule as root before
/// listening; malformed requests and tests never create or repair a host right.
enum VPhoneHelperAuthorization {
    static var definition: [String: Any] {
        ["class": "user", "group": "admin", "authenticate-user": true, "timeout": 300,
         "shared": false, "allow-root": false, "version": 1]
    }

    static func ruleIsIntact(_ rule: [String: Any]) -> Bool {
        rule["class"] as? String == "user" && rule["group"] as? String == "admin"
            && rule["authenticate-user"] as? Bool == true && rule["shared"] as? Bool == false
            && (rule["timeout"] as? Int).map { (0...300).contains($0) } == true
            && rule["rule"] == nil && rule["allow-root"] as? Bool == false
    }

    static func registerRight() throws {
        guard geteuid() == 0 else { throw VPhoneHelperError("Helper registration requires root.") }
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            throw VPhoneHelperError("Unable to create helper authorization reference.")
        }
        defer { AuthorizationFree(reference, []) }
        guard AuthorizationRightSet(reference, VPhoneHelperIdentity.privilegedRight, definition as CFDictionary,
                                    "Install verified VPhone Core Bundles" as CFString, nil, nil) == errAuthorizationSuccess else {
            throw VPhoneHelperError("Unable to register administrator-only helper authorization.")
        }
        try requireIntactRule()
    }

    static func requireIntactRule() throws {
        var rule: CFDictionary?
        guard AuthorizationRightGet(VPhoneHelperIdentity.privilegedRight, &rule) == errAuthorizationSuccess,
              let value = rule as? [String: Any], ruleIsIntact(value) else {
            throw VPhoneHelperError("The helper authorization rule is missing or changed. Reinstall the signed helper.")
        }
    }

    static func require(_ external: Data) throws {
        guard external.count == Int(kAuthorizationExternalFormLength) else {
            throw VPhoneHelperError("The request lacks a valid administrator authorization form.")
        }
        try requireIntactRule()
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form.bytes) { external.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else {
            throw VPhoneHelperError("The administrator authorization form is invalid.")
        }
        defer { AuthorizationFree(reference, []) }
        try obtainRight(VPhoneHelperIdentity.privilegedRight, reference: reference)
    }

    static func obtainRight(_ name: String, reference: AuthorizationRef) throws {
        let status = name.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        if status == errAuthorizationCanceled { throw CancellationError() }
        guard status == errAuthorizationSuccess else { throw VPhoneHelperError("Administrator authorization is required.") }
    }
}
