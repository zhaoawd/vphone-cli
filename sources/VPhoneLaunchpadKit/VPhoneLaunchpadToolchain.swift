import Darwin
import Foundation
import Security

// MARK: - Manifest

/// `Contents/Resources/embedded-toolchain.json`, written by
/// `scripts/build_launchpad.sh` before the outer app is signed. The outer
/// signature seals it, so its cdhashes pin the nested executables.
public struct VPhoneLaunchpadToolchainManifest: Codable, Equatable, Sendable {
    public static let schemaName = "vphone.launchpad.embedded-toolchain"
    public static let fileName = "embedded-toolchain.json"

    public struct Executable: Codable, Equatable, Sendable {
        public let cdhash: String

        public init(cdhash: String) {
            self.cdhash = cdhash
        }
    }

    public let schema: String
    public let version: Int
    public let gitHash: String
    public let vphoneCLI: Executable
    public let vphoneVM: Executable

    public init(gitHash: String, vphoneCLI: Executable, vphoneVM: Executable) {
        schema = Self.schemaName
        version = 1
        self.gitHash = gitHash
        self.vphoneCLI = vphoneCLI
        self.vphoneVM = vphoneVM
    }
}

// MARK: - Toolchain

/// The `vphone-cli` Launchpad runs: only the copy embedded at
/// `Contents/Helpers/vphone-cli.app` of the running app, after its signature
/// and cdhashes check out. No environment variable, default or argument can
/// name another executable; a value of this type exists only after
/// `verify(appBundle:)` succeeded.
public struct VPhoneLaunchpadToolchain: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case layout
        case nestedSignature
        case outerSignature
        case manifest
        case cdhash
    }

    public struct Failure: Error, Equatable, Sendable {
        public let step: Step
        public let reason: String
    }

    public let appBundle: URL
    public let helperApp: URL
    public let executable: URL
    public let vmExecutable: URL
    public let manifest: VPhoneLaunchpadToolchainManifest

    static let helperPath = "Contents/Helpers/vphone-cli.app"

    /// Verifies the toolchain inside the running app.
    public static func verifyEmbedded() -> Result<VPhoneLaunchpadToolchain, Failure> {
        verify(appBundle: Bundle.main.bundleURL)
    }

    /// Internal so tests can verify fixture apps; the product only reaches it
    /// through `verifyEmbedded()`.
    static func verify(appBundle: URL) -> Result<VPhoneLaunchpadToolchain, Failure> {
        let app = appBundle.standardizedFileURL
        let helper = app.appendingPathComponent(helperPath, isDirectory: true)
        let cli = helper.appendingPathComponent("Contents/MacOS/vphone-cli")
        let vm = helper.appendingPathComponent("Contents/MacOS/vphone-vm")
        let manifestURL = app.appendingPathComponent("Contents/Resources/\(VPhoneLaunchpadToolchainManifest.fileName)")

        // 1. Every component below the app is a real directory or file.
        let layout: [(String, Kind)] = [
            ("Contents", .directory),
            ("Contents/Helpers", .directory),
            (helperPath, .directory),
            ("\(helperPath)/Contents", .directory),
            ("\(helperPath)/Contents/MacOS", .directory),
            ("\(helperPath)/Contents/MacOS/vphone-cli", .executable),
            ("\(helperPath)/Contents/MacOS/vphone-vm", .executable),
            ("Contents/Resources", .directory),
            ("Contents/Resources/\(VPhoneLaunchpadToolchainManifest.fileName)", .file),
        ]
        for (relative, kind) in layout {
            if let problem = checkComponent(app.appendingPathComponent(relative), kind) {
                return .failure(Failure(step: .layout, reason: "\(relative): \(problem)"))
            }
        }

        // 2. The nested app, with its nested code and resources, is intact.
        if let problem = checkValidity(helper) {
            return .failure(Failure(step: .nestedSignature, reason: problem))
        }
        // 3. The outer signature seals the manifest and the nested app.
        if let problem = checkValidity(app) {
            return .failure(Failure(step: .outerSignature, reason: problem))
        }

        // 4. The manifest decodes and names this schema.
        let manifest: VPhoneLaunchpadToolchainManifest
        do {
            manifest = try JSONDecoder().decode(VPhoneLaunchpadToolchainManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return .failure(Failure(step: .manifest, reason: "\(VPhoneLaunchpadToolchainManifest.fileName): \(error)"))
        }
        guard manifest.schema == VPhoneLaunchpadToolchainManifest.schemaName, manifest.version == 1 else {
            return .failure(Failure(step: .manifest, reason: "unsupported schema \(manifest.schema) version \(manifest.version)"))
        }

        // 5. The executables are the ones the manifest recorded at build time.
        for (name, url, expected) in [("vphone-cli", cli, manifest.vphoneCLI.cdhash), ("vphone-vm", vm, manifest.vphoneVM.cdhash)] {
            guard let actual = cdhash(of: url) else {
                return .failure(Failure(step: .cdhash, reason: "\(name): cdhash unreadable"))
            }
            guard actual == expected.lowercased() else {
                return .failure(Failure(step: .cdhash, reason: "\(name): cdhash \(actual) does not match manifest \(expected)"))
            }
        }

        return .success(VPhoneLaunchpadToolchain(
            appBundle: app, helperApp: helper, executable: cli, vmExecutable: vm, manifest: manifest
        ))
    }

    // MARK: - Checks

    enum Kind {
        case directory
        case file
        case executable
    }

    /// Why `url` is not a real component of `kind`, or nil. `lstat` so a
    /// symbolic link is reported, never followed.
    static func checkComponent(_ url: URL, _ kind: Kind) -> String? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return "missing (\(String(cString: strerror(errno))))"
        }
        let type = status.st_mode & S_IFMT
        if type == S_IFLNK {
            return "is a symbolic link"
        }
        switch kind {
        case .directory:
            return type == S_IFDIR ? nil : "is not a directory"
        case .file:
            return type == S_IFREG ? nil : "is not a regular file"
        case .executable:
            guard type == S_IFREG else {
                return "is not a regular file"
            }
            return status.st_mode & S_IXUSR != 0 ? nil : "is not executable"
        }
    }

    /// Strict static validation including nested code and resources, or the
    /// failure as text.
    static func checkValidity(_ url: URL) -> String? {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            return "\(url.lastPathComponent): cannot read code (OSStatus \(created))"
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status == errSecSuccess else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
            return "\(url.lastPathComponent): signature invalid (OSStatus \(status)) \(detail)"
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The code directory hash `codesign -d` reports as `CDHash`, lowercase hex.
    public static func cdhash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
