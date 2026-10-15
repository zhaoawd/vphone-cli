import Foundation
import Security

/// Ad hoc signatures establish integrity, not publisher identity. The caller must
/// obtain the expected archive digest through a separately trusted channel.
enum VPhoneBundleCodeSignature {
    static func verify(_ url: URL) throws {
        let code = try staticCode(url)
        // Do not block a cooperative executor waiting for resource work queued
        // to the same exhausted pool. This changes scheduling, not validation.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
            | kSecCSCheckNestedCode | kSecCSSingleThreaded)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        let detail = error?.takeRetainedValue()
        guard status == errSecSuccess else {
            throw VPhoneBundleStoreError("Invalid code signature at \(url.path): \(detail.map { String(describing: $0) } ?? String(status))")
        }
    }

    static func cdhash(_ url: URL) throws -> String {
        // Reading a CodeDirectory alone would miss a modified executable page.
        try verify(url)
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(try staticCode(url), SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
            throw VPhoneBundleStoreError("Missing cdhash: \(url.path)")
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw VPhoneBundleStoreError("Unable to read code signature: \(url.path)")
        }
        return code
    }
}
