import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - fw cache

struct VPhoneFWCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "List the shared IPSW cache, or adopt an entry that has no completion marker",
        subcommands: [VPhoneFWCacheListCommand.self, VPhoneFWCacheAdoptCommand.self])
}

struct VPhoneFWCacheDirectoryOption: ParsableArguments {
    @Option(help: "IPSW cache directory (default: the shared cache fw prepare uses, $VPHONE_ROOT/ipsws or ~/.vphone/ipsws)")
    var cacheDir: String?

    var directory: URL {
        cacheDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? VPhoneResources.resolve().ipswCacheDir
    }
}

// MARK: - list

struct VPhoneFWCacheListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show each cache entry and its completion marker state (read-only)")

    @OptionGroup var cache: VPhoneFWCacheDirectoryOption
    @Flag(help: "Emit JSON") var json = false

    func run() throws {
        let directory = cache.directory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ValidationError("The IPSW cache \(directory.path) does not exist.")
        }
        let rows = try VPhoneIPSWCache.list(directory)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
            return
        }
        print("IPSW cache: \(directory.path)")
        guard !rows.isEmpty else {
            print("(empty)")
            return
        }
        let width = rows.map(\.state.count).max() ?? 0
        for row in rows {
            let state = row.state.padding(toLength: width, withPad: " ", startingAt: 0)
            let size = row.size.map { VPhoneProgressBar.bytes($0) } ?? "-"
            print("\(state)  \(size.padding(toLength: 9, withPad: " ", startingAt: 0))  \(row.name)")
            if let version = row.version, let build = row.build { print("    firmware: \(version) (\(build))") }
            if let source = row.source { print("    \(row.kind == "directory" ? "extracted from" : "source"): \(source)") }
            if let digest = row.sha256 { print("    sha256: \(digest)") }
            if let detail = row.detail { print("    \(detail)") }
        }
    }
}

// MARK: - adopt

struct VPhoneFWCacheAdoptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Write a completion marker for an existing cache entry so fw prepare reuses it",
        discussion: """
        Hashes the whole file (SHA-256), reads its BuildManifest, and records size, inode, \
        mtime and digest in the same marker a download writes, marked "adopted" because the \
        content was not checked against a transfer from the source. Nothing is deleted.

        A file needs the source fw prepare will use for it: --source <url>, or the catalog \
        URL whose cache name equals the file name. A PCC URL whose path holds a 64-digit \
        hexadecimal digest must match the file's SHA-256. An extraction directory can be \
        adopted after its IPSW (<dir>.ipsw) is a usable entry; its members are compared \
        by name, type and size.
        """)

    @OptionGroup var cache: VPhoneFWCacheDirectoryOption
    @Argument(help: "Cache entry: a file or extraction directory directly inside the cache, or its name")
    var entry: String
    @Option(help: "The source fw prepare uses for this entry: an HTTP(S) URL, or the entry's own path when fw prepare is given it as a local file")
    var source: String?
    @Option(name: .customLong("expect-sha256"), help: "Refuse unless the file's SHA-256 equals this value")
    var expectSHA256: String?

    func run() throws {
        let bar = VPhoneProgressBar(label: "Hashing")
        let interactive = isatty(FileHandle.standardError.fileDescriptor) != 0
        var reported = -1
        let progress: (Int64, Int64) -> Void = { done, total in
            if interactive {
                bar.update(done: done, total: total)
            } else if total > 0 {
                let decile = Int(done * 10 / total)
                if decile != reported {
                    reported = decile
                    FileHandle.standardError.write(Data("Hashing: \(decile * 10)% (\(VPhoneProgressBar.bytes(done)) of \(VPhoneProgressBar.bytes(total)))\n".utf8))
                }
            }
        }
        let started = Date()
        let result: VPhoneIPSWCache.Adoption
        do {
            result = try VPhoneIPSWCache.adopt(
                entry, in: cache.directory, source: source, expectedSHA256: expectSHA256, progress: progress)
        } catch {
            if interactive, reported >= 0 { FileHandle.standardError.write(Data("\n".utf8)) }
            throw error
        }
        if interactive, result.outcome == .adopted, !result.isDirectory { bar.finish() }

        let name = result.entry.lastPathComponent
        switch result.outcome {
        case .alreadyUsable:
            print("\(name) already has a usable completion marker (\(result.adopted ? "adopted" : "written when it was cached")); nothing changed.")
        case .adopted:
            print("Adopted \(name) (source not verified by download).")
        }
        if let source = result.source {
            print("  source: \(source)\(result.sourceFromCatalog ? " (from the firmware catalog)" : "")")
        }
        if let version = result.version, let build = result.build {
            print("  firmware: \(version) (\(build))\(result.productTypes.isEmpty ? "" : ", \(result.productTypes.joined(separator: ", "))")")
        }
        print("  \(result.isDirectory ? "IPSW sha256" : "sha256"): \(result.sha256)")
        print("  \(result.isDirectory ? "IPSW size" : "size"): \(result.size) bytes")
        if !result.checks.isEmpty { print("  checks: \(result.checks.joined(separator: ", "))") }
        if result.outcome == .adopted, !result.isDirectory {
            print(String(format: "  hashed in %.1f s", Date().timeIntervalSince(started)))
        }
    }
}
