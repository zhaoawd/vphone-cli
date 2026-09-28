// Native archive commands adapted from upstream 2.0.8; no recursive permission widening.
import ArgumentParser
import Foundation
import VPhoneArchiveKit

struct VPhoneArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Unpack and pack archives",
        discussion: """
        The compressor is detected when reading, so there is no --zstd to pass
        and no way to pass the wrong one.
        """,
        subcommands: [
            VPhoneArchiveExtractCommand.self, VPhoneArchiveCreateCommand.self, VPhoneArchiveDecompressCommand.self,
            VPhoneArchiveListCommand.self, VPhoneArchiveCatCommand.self, VPhoneArchiveFingerprintCommand.self,
        ],
        defaultSubcommand: VPhoneArchiveExtractCommand.self,
    )
}

// MARK: - extract

struct VPhoneArchiveExtractCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Unpack an archive into a directory",
    )

    @Option(
        name: [.customShort("f"), .long],
        help: "Archive to read",
        transform: URL.init(fileURLWithPath:),
    )
    var file: URL

    @Option(
        name: [.customShort("C"), .customLong("directory")],
        help: "Where to unpack it",
        transform: URL.init(fileURLWithPath:),
    )
    var destination: URL = .init(fileURLWithPath: ".")

    @Flag(
        name: [.customShort("p"), .customLong("preserve-permissions")],
        help: "Restore modes, and — as root — the archive's numeric uid/gid",
    )
    var preservePermissions = false

    @Flag(
        name: .customLong("no-overwrite-dir"),
        help: "Leave an existing directory's mode, owner and mtime alone",
    )
    var noOverwriteDir = false

    @Flag(
        name: .customLong("numeric-owner"),
        help: "Accepted for compatibility; -p restores numeric ownership, otherwise files belong to the current user",
    )
    var numericOwner = false

    @Flag(name: [.customShort("v"), .long], help: "Print each member as it is written")
    var verbose = false

    func run() throws {
        // --preserve-permissions is what the install scripts pass GNU tar, and
        // they pass it precisely where they are running as root and unpacking
        // onto a mounted guest volume. Ownership by number is not a separate
        // choice: resolving the archive's `mobile` against the host's passwd
        // database is how files end up owned by an unrelated macOS account.
        var options = preservePermissions
            ? VPhoneArchiveExtractOptions.ontoGuestVolume
            : VPhoneArchiveExtractOptions.intoHostDirectory
        options.noOverwriteDir = noOverwriteDir

        let written = try VPhoneArchiveExtractor.extract(
            file,
            into: destination,
            options: options,
            progress: verbose ? { print($0.currentPath) } : nil,
        )
        if !verbose {
            print("extracted \(written) entries to \(destination.path)")
        }
    }
}

// MARK: - create

struct VPhoneArchiveCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Pack a directory into an archive",
    )

    @Option(
        name: [.customShort("f"), .long],
        help: "New archive path outside the source directory; existing paths are refused",
        transform: URL.init(fileURLWithPath:),
    )
    var file: URL

    @Option(
        name: [.customShort("C"), .customLong("directory")],
        help: "Directory to pack",
        transform: URL.init(fileURLWithPath:),
    )
    var source: URL = .init(fileURLWithPath: ".")

    @Option(help: "tar dialect: gnutar, pax or ustar")
    var format: String = "gnutar"

    @Flag(name: .customLong("zstd"), help: "Compress with zstd")
    var zstd = false

    @Flag(name: .customLong("xz"), help: "Compress with xz")
    var xz = false

    @Option(help: "Compression level")
    var level: Int?

    @Option(help: "fnmatch pattern to leave out; repeatable")
    var exclude: [String] = []

    @Flag(name: [.customShort("v"), .long], help: "Print each member as it is added")
    var verbose = false

    func validate() throws {
        if zstd, xz {
            throw ValidationError("Use either --zstd or --xz, not both.")
        }
        guard VPhoneArchiveFormat(rawValue: format) != nil else {
            throw ValidationError(
                "Unknown format '\(format)'. Use gnutar, pax, or ustar.",
            )
        }
    }

    func run() throws {
        // gnutar by default, and it matters: `vm export` feeds a consumer that
        // reads pax extended headers as an mtree listing and dies with "Line
        // too long", and ustar cannot hold a member over 8 GB.
        let tarFormat = VPhoneArchiveFormat(rawValue: format) ?? .gnutar
        let compression: VPhoneArchiveCompression = if zstd {
            .zstd(level: level ?? 3)
        } else if xz {
            .xz(level: level ?? 9)
        } else {
            .none
        }

        let written = try VPhoneArchiveWriter.create(
            archive: file,
            from: source,
            format: tarFormat,
            compression: compression,
            excluding: exclude,
            progress: verbose ? { print($0.currentPath) } : nil,
        )
        if !verbose {
            print("packed \(written) entries into \(file.path)")
        }
    }
}

// MARK: - decompress

struct VPhoneArchiveDecompressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decompress",
        abstract: "Unwrap a single compressed file, leaving what is inside packed",
        discussion: """
        Remove the compression layer. The result is still an archive;
        use `extract` to unpack it. The output path must not already exist.
        """,
    )

    @Option(
        name: [.customShort("f"), .long],
        help: "File to decompress",
        transform: URL.init(fileURLWithPath:),
    )
    var file: URL

    @Option(
        name: [.customShort("o"), .long],
        help: "Where to write the result",
        transform: URL.init(fileURLWithPath:),
    )
    var output: URL

    func run() throws {
        try VPhoneArchiveWriter.decompress(file, to: output)
        print("decompressed \(file.lastPathComponent) → \(output.path)")
    }
}

// MARK: - list

struct VPhoneArchiveListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List an archive's members",
    )

    @Option(
        name: [.customShort("f"), .long],
        help: "Archive to read",
        transform: URL.init(fileURLWithPath:),
    )
    var file: URL

    @Flag(name: [.customShort("v"), .long], help: "Include mode, owner and size")
    var verbose = false

    func run() throws {
        let entries = try VPhoneArchiveReader.entries(of: file)
        for entry in entries {
            if verbose {
                let mode = String(entry.mode, radix: 8)
                print("\(mode)\t\(entry.uid):\(entry.gid)\t\(entry.size)\t\(entry.path)")
            } else {
                print(entry.path)
            }
        }
    }
}

// MARK: - cat

struct VPhoneArchiveCatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Write one member to stdout without unpacking the archive",
    )

    @Option(
        name: [.customShort("f"), .long],
        help: "Archive to read",
        transform: URL.init(fileURLWithPath:),
    )
    var file: URL

    @Argument(help: "Member path inside the archive")
    var member: String

    func run() throws {
        let data = try VPhoneArchiveReader.readMember(member, from: file)
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - fingerprint

struct VPhoneArchiveFingerprintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fingerprint",
        abstract: "Describe a directory tree completely, or compare two of them",
        discussion: """
        For deciding whether GNU tar and vphone-archive produced the same
        result. `diff -r` and `stat` cannot answer that: they miss ACLs,
        extended attributes, which files are hardlinked to which, and
        sparse-file occupancy — the four things most likely to differ, and
        all four of which change how a guest behaves.

        With one path, writes JSON. With two, prints the differences and exits
        non-zero if there are any.
        """,
    )

    @Argument(help: "Tree to describe", transform: URL.init(fileURLWithPath:))
    var tree: URL

    @Argument(
        help: "Second tree; given, the two are compared",
        transform: URL.init(fileURLWithPath:),
    )
    var other: URL?

    @Flag(
        name: .customLong("no-content-hashes"),
        help: "Skip file digests — much faster, and enough to compare metadata",
    )
    var noContentHashes = false

    func run() throws {
        let first = try VPhoneTreeFingerprint.capture(tree, includeContentHashes: !noContentHashes)

        guard let other else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try print(String(decoding: encoder.encode(first), as: UTF8.self))
            return
        }

        let second = try VPhoneTreeFingerprint.capture(
            other,
            includeContentHashes: !noContentHashes,
        )
        let differences = first.differences(from: second)
        guard differences.isEmpty else {
            for line in differences {
                print(line)
            }
            print("\n\(differences.count) difference(s)")
            throw ExitCode(1)
        }
        print("identical (\(first.entries.count) entries)")
    }
}
