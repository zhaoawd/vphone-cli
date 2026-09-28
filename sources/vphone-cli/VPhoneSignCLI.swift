// Native signing commands adapted from upstream 2.0.8 (9d218de).
// Existing build and CFW signing paths retain their current external tools.

import ArgumentParser
import Foundation
import VPhoneSign

// MARK: - sign

struct VPhoneSignCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign an ARM Mach-O with the native signing library",
        discussion: """
        The default style matches the fixed ldid compatibility fixtures. Use
        --apple-adhoc for a signature accepted by host codesign verification.
        --merge preserves existing entitlements and applies the supplied plist.
        Without --merge, existing entitlements are replaced.

        Only regular ARM Mach-O files are accepted. Signing stages a temporary
        file beside the destination, preserves its mode, and replaces it by
        rename. Existing build and CFW scripts retain their current signers.
        """,
    )

    @Argument(help: "The Mach-O to sign, in place", transform: URL.init(fileURLWithPath:))
    var file: URL

    /// Long spellings only, deliberately. ldid's short flags take their value
    /// attached (-S"$ent", -K"$p12"), which ArgumentParser reads as an unknown
    /// option; offering -S and -K here would invite exactly that call and answer
    /// it with a parse error about something else.
    @Option(
        name: .customLong("entitlements"),
        help: "Entitlements plist to embed, as the file holds it",
        transform: URL.init(fileURLWithPath:),
    )
    var entitlements: URL?

    @Option(
        name: .customLong("identifier"),
        help: "Signing identifier. Defaults to the file's name, as ldid does.",
    )
    var identifier: String?

    @Flag(name: .customLong("merge"), help: "Merge over the file's existing entitlements")
    var merge = false

    @Option(
        name: .customLong("pkcs12"),
        help: "Sign for real with this .p12 (no password) instead of ad-hoc",
        transform: URL.init(fileURLWithPath:),
    )
    var pkcs12: URL?

    @Flag(
        name: .customLong("apple-adhoc"),
        help: "Write an ad-hoc signature in Apple's shape (codesign --sign -) rather than ldid's",
    )
    var appleAdHoc = false

    func validate() throws {
        if appleAdHoc && pkcs12 != nil {
            throw ValidationError("--apple-adhoc cannot be combined with --pkcs12")
        }
    }

    func run() throws {
        var options = VPhoneSignOptions()
        options.identifier = identifier
        options.entitlements = try entitlements.map {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
        options.mergesExisting = merge
        options.style = appleAdHoc ? .appleAdHoc : .ldid
        if let pkcs12 {
            options.identity = try VPhoneSignIdentity(
                pkcs12: Data(contentsOf: pkcs12, options: .mappedIfSafe),
                password: "",
            )
        }
        try VPhoneSigner.sign(fileAt: file, options: options)
    }
}

// MARK: - dump-entitlements

struct VPhoneDumpEntitlementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-entitlements",
        abstract: "Print a Mach-O's embedded entitlements (replaces `ldid -e`)",
        discussion: """
        Writes the entitlements of every slice that carries any, in slice order,
        exactly as the signature stores them and with nothing in between —
        which is what `ldid -e` does, and what the installers depend on when
        they redirect this into a plist and feed it back to `sign --merge`.

        A slice with no entitlements contributes nothing, so a file with none at
        all prints nothing and still exits zero.
        """,
    )

    @Argument(help: "The Mach-O to read", transform: URL.init(fileURLWithPath:))
    var file: URL

    func run() throws {
        // Raw bytes, not print(): the blob is a plist as the signature stores
        // it, and a trailing newline per slice would be a byte ldid did not
        // write into a file that gets parsed.
        let out = FileHandle.standardOutput
        for blob in try VPhoneSigner.entitlements(ofFileAt: file) {
            out.write(blob)
        }
    }
}
