// PatchExperimentRecorder.swift — Collects run conditions, runs the firmware pipeline
// and writes the C5 experiment record plus its derived text summary.

import CryptoKit
import Darwin
import Foundation
import VPhoneCore

// MARK: - Environment

/// Host facts the recorder cannot derive from the pipeline. Tests inject fixed values.
public struct PatchExperimentEnvironment {
    public var buildCommit: String?
    public var executable: URL?
    /// Git work tree used for source state; nil records the source as unavailable.
    public var sourceRoot: URL?
    /// Directory that may contain `build-dependencies.json` (app bundle resources).
    public var resourcesBase: URL?
    /// Directory holding `apfs_sealvolume_<version>` for the less variant.
    public var sealDirectory: URL?
    public var pythonExecutable: () throws -> URL
    public var gitExecutable: URL
    public var now: () -> Date
    public var makeRunID: () -> String
    /// Failure injection for durable writes: (destination, step).
    public var writeHook: (URL, PatchExperimentRecord.WriteStep) throws -> Void
    /// Reports secondary errors (for example a record write failure after a run error).
    public var diagnostics: (String) -> Void

    public init(
        buildCommit: String?,
        executable: URL?,
        sourceRoot: URL?,
        resourcesBase: URL?,
        sealDirectory: URL?,
        pythonExecutable: @escaping () throws -> URL,
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        now: @escaping () -> Date = Date.init,
        makeRunID: @escaping () -> String = { UUID().uuidString.lowercased() },
        writeHook: @escaping (URL, PatchExperimentRecord.WriteStep) throws -> Void = { _, _ in },
        diagnostics: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.buildCommit = buildCommit
        self.executable = executable
        self.sourceRoot = sourceRoot
        self.resourcesBase = resourcesBase
        self.sealDirectory = sealDirectory
        self.pythonExecutable = pythonExecutable
        self.gitExecutable = gitExecutable
        self.now = now
        self.makeRunID = makeRunID
        self.writeHook = writeHook
        self.diagnostics = diagnostics
    }

    /// Nearest ancestor of `url` containing both `.git` and `Package.swift`.
    public static func locateSourceRoot(from url: URL) -> URL? {
        var directory = url.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<10 {
            let fm = FileManager.default
            if fm.fileExists(atPath: directory.appendingPathComponent(".git").path),
               fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}

// MARK: - Recorder

public struct PatchExperimentRecorder {
    typealias Record = PatchExperimentRecord

    /// Paths whose state determines the built tool and its runtime scripts.
    static let sourceScope = ["Makefile", "Package.resolved", "Package.swift", "requirements.txt", "scripts", "sources", "vendor"]

    public let recordURL: URL
    public let environment: PatchExperimentEnvironment

    public init(recordURL: URL, environment: PatchExperimentEnvironment) {
        self.recordURL = recordURL.standardizedFileURL
        self.environment = environment
    }

    /// Writes a `running` record, runs `patchAllStructured`, then writes the final record
    /// and its summary. A failure to write the initial record aborts before patching.
    /// A run error is always rethrown unchanged; a later record write error is reported
    /// through `diagnostics` in that case and thrown otherwise.
    public func run(_ pipeline: FirmwarePipeline, ablate: [String], allowOutput: Bool) throws -> PatchRunReport {
        // A record inside a transaction root would change the input digests it records.
        let parent = recordURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let protected = ((try? pipeline.transactionRoots()) ?? [])
            + [".firmware-transaction", ".firmware-history"].map { pipeline.vmDirectory.appendingPathComponent($0) }
        for root in protected.map({ $0.resolvingSymlinksInPath().path })
        where parent == root || parent.hasPrefix(root + "/") || recordURL.resolvingSymlinksInPath().path == root {
            throw PatchExperimentRecordError(message: "Record path must not be inside firmware input or transaction data: \(recordURL.path)")
        }
        let options = Record.Options(
            variant: pipeline.variant.rawValue, forceExcGuard: pipeline.forceExcGuard, frida: pipeline.enableFrida,
            noBinpack: pipeline.noBinpack, noVphoned: pipeline.noVphoned,
            ablate: Set(ablate.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).sorted(),
            allowAblationOutput: allowOutput)
        let conditions = collectConditions(pipeline, options: options)
        let pending = "run in progress"
        let running = Record(
            schema: Record.schemaName, schemaVersion: Record.currentSchemaVersion,
            runID: environment.makeRunID(), startedAt: Self.timestamp(environment.now()), finishedAt: nil,
            status: .running, failedStage: nil, error: nil,
            conditions: conditions, conditionDigest: try Record.digest(of: conditions),
            patch: .init(report: nil, reason: pending, reportSHA256: nil, failedRequired: [],
                         plannedComponents: [], processedComponents: [], notRunComponents: []),
            transaction: .init(state: "none", reason: pending, location: nil, journal: nil),
            outputs: .init(availability: "pending", reason: pending, files: [], roots: []),
            run: .init(vmDirectory: pipeline.vmDirectory.path, executable: environment.executable?.path,
                       sourceRoot: environment.sourceRoot?.path, recordPath: recordURL.path))
        let summaryURL = Record.summaryURL(for: recordURL)
        // A summary from an earlier run must not sit next to this run's record.
        if unlink(summaryURL.path) != 0, errno != ENOENT {
            throw PatchExperimentRecordError(message: "Cannot remove stale summary \(summaryURL.path): \(String(cString: strerror(errno)))")
        }
        try running.validate()
        try write(running.encoded(), to: recordURL)

        var report: PatchRunReport?
        var runError: (any Error)?
        do { report = try pipeline.patchAllStructured(ablate: ablate, allowOutput: allowOutput) } catch { runError = error }

        do {
            let final = Self.finish(running, trace: pipeline.trace, vmDirectory: pipeline.vmDirectory, report: report,
                                    error: runError, finishedAt: Self.timestamp(environment.now()))
            try final.validate()
            try write(final.encoded(), to: recordURL)
            // The summary is rendered from the decoded JSON bytes, not a separate model.
            let decoded = try Record.decode(Data(contentsOf: recordURL))
            try write(Data(decoded.summary().utf8), to: summaryURL)
        } catch {
            if let runError {
                environment.diagnostics("[record] experiment record not completed (\(recordURL.path)): \(error)")
                throw runError
            }
            throw error
        }
        if let runError { throw runError }
        return report!
    }

    private func write(_ data: Data, to url: URL) throws {
        try Record.writeDurably(data, to: url) { step in try environment.writeHook(url, step) }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Final Record

    /// Derives status, patch, transaction and outputs from the pipeline trace.
    static func finish(_ running: Record, trace: FirmwareRunTrace, vmDirectory: URL, report: PatchRunReport?,
                       error: (any Error)?, finishedAt: String) -> Record {
        var record = running
        record.finishedAt = finishedAt
        let options = record.conditions.options
        let stage = trace.stage.rawValue

        let effective = report ?? trace.gates.map {
            FirmwarePipeline.makeReport(variant: options.variant, gates: $0, components: trace.componentReports)
        }
        let processed = trace.processedComponents
        record.patch = .init(
            report: effective,
            reason: effective == nil ? "run stopped at stage \(stage) before patch gates were evaluated"
                : report == nil ? "partial report: run stopped at stage \(stage)" : nil,
            reportSHA256: effective.flatMap { try? Record.sha256(Record.canonicalData($0)) },
            failedRequired: effective?.failedRequired.map(\.description) ?? [],
            plannedComponents: trace.plannedComponents, processedComponents: processed,
            notRunComponents: trace.plannedComponents.filter { !processed.contains($0) })

        let journal = trace.transaction?.journalSnapshot
        if let transaction = trace.transaction, let journal {
            let committed = journal.phase == .committed
            record.transaction = .init(
                state: committed ? "committed" : "uncommitted",
                reason: committed ? nil : "journal phase \(journal.phase.rawValue) is not committed; staged files are not published output",
                location: transaction.archiveURL.map { relativePath($0, to: vmDirectory) } ?? ".firmware-transaction",
                journal: journal)
        } else {
            let reason: String
            if error == nil, options.isDryRun { reason = "ablation dry-run does not create a firmware transaction" }
            else if trace.stage == .stageInputs { reason = "transaction initialization did not complete; .firmware-transaction may remain for --recover" }
            else { reason = "run stopped at stage \(stage) before a firmware transaction was created" }
            record.transaction = .init(state: "none", reason: reason, location: nil, journal: nil)
        }

        record.status = .succeeded
        func fail(_ status: Record.Status, stage: String, component: String?, _ message: String) {
            record.status = status
            record.failedStage = .init(stage: stage, component: component)
            record.error = message
        }
        let component = trace.stage == .patch ? trace.component : nil
        if let error {
            fail(error is CancellationError ? .cancelled : .failed, stage: stage, component: component, String(describing: error))
        } else if let report, !report.failedRequired.isEmpty {
            fail(.failed, stage: FirmwareRunStage.patch.rawValue,
                 component: report.components.first { $0.hasRequiredFailure }?.component,
                 "required patches failed: " + report.failedRequired.map(\.description).joined(separator: ", "))
        } else if let journal, journal.phase != .committed {
            fail(.failed, stage: FirmwareRunStage.commit.rawValue, component: nil,
                 "firmware transaction \(journal.id) is \(journal.phase.rawValue), not committed")
        } else if journal == nil, !options.isDryRun {
            fail(.failed, stage: stage, component: nil, "output run finished without a firmware transaction")
        } else if let journal {
            let inputs = Dictionary(record.conditions.inputs.roots.map { ($0.path, $0.digest) }, uniquingKeysWith: { a, _ in a })
            let mismatched = journal.entries.filter { inputs[$0.name] != .some($0.original) }.map(\.name)
            if !mismatched.isEmpty {
                fail(.failed, stage: "record", component: nil,
                     "recorded input root digests differ from the transaction journal: \(mismatched.joined(separator: ", "))")
            }
        }

        if record.status == .succeeded, let journal, journal.phase == .committed {
            record.outputs = hashOutputs(inputs: record.conditions.inputs, journal: journal, vmDirectory: vmDirectory)
        } else if record.status == .succeeded {
            record.outputs = .unavailable("ablation dry-run: firmware was not written")
        } else {
            record.outputs = .unavailable("run \(record.status.rawValue); no committed firmware transaction output is recorded")
        }
        return record
    }

    static func hashOutputs(inputs: Record.Artifacts, journal: FirmwareTransaction.Journal, vmDirectory: URL) -> Record.Artifacts {
        let files = inputs.files.map { input in
            fileEntry(vmDirectory.appendingPathComponent(input.path), path: input.path, components: input.components)
        }
        let components = Dictionary(inputs.roots.map { ($0.path, $0.components) }, uniquingKeysWith: { a, _ in a })
        let roots = journal.entries.map { entry in
            Record.FileDigest(path: entry.name, components: components[entry.name] ?? [], algorithm: Record.treeDigestAlgorithm,
                              sizeBytes: nil, digest: entry.output,
                              reason: entry.output == nil ? "journal has no output digest" : nil)
        }.sorted { $0.path < $1.path }
        return artifacts(files: files, roots: roots)
    }

    static func artifacts(files: [Record.FileDigest], roots: [Record.FileDigest]) -> Record.Artifacts {
        let missing = (files + roots).filter { $0.digest == nil }.count
        return .init(availability: missing == 0 ? "available" : "unavailable",
                     reason: missing == 0 ? nil : "\(missing) artifact digest(s) unavailable",
                     files: files, roots: roots)
    }

    // MARK: - Conditions

    func collectConditions(_ pipeline: FirmwarePipeline, options: Record.Options) -> Record.Conditions {
        let restore = try? pipeline.findRestoreDirectory()
        func manifestValue(_ manifest: String, _ key: String) -> Record.Known {
            guard let restore else { return .unknown("no *Restore* directory found in the VM directory") }
            return FirmwarePipeline.readManifestString(restore, manifest: manifest, key: key).map(Record.Known.known)
                ?? .unknown("\(key) missing or unreadable in \(manifest)")
        }
        let firmware = Record.Firmware(
            iPhone: .init(manifest: "iPhone-BuildManifest.plist",
                          productVersion: manifestValue("iPhone-BuildManifest.plist", "ProductVersion"),
                          buildVersion: manifestValue("iPhone-BuildManifest.plist", "ProductBuildVersion")),
            cloudOS: .init(manifest: "BuildManifest.plist",
                           productVersion: manifestValue("BuildManifest.plist", "ProductVersion"),
                           buildVersion: manifestValue("BuildManifest.plist", "ProductBuildVersion")),
            origin: .unknown("fw prepare does not record the IPSW source; it is not inferred from directory names"))

        let isLess = pipeline.variant == .less
        let notUsed = "not used outside the less variant"
        var python = Record.Known.unknown(notUsed)
        if isLess {
            do {
                let result = try VPhoneProcessRunner.runCapturing(try environment.pythonExecutable(), ["--version"])
                let text = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                python = result.succeeded && !text.isEmpty ? .known(text) : .unknown("python --version failed: \(text)")
            } catch { python = .unknown("python unavailable: \(error)") }
        }
        var sealTool = Record.Known.unknown(notUsed)
        if isLess {
            if let directory = environment.sealDirectory, let version = firmware.cloudOS.productVersion.value {
                sealTool = Self.sha256Known(directory.appendingPathComponent("apfs_sealvolume_\(version)"))
            } else {
                sealTool = .unknown("seal directory or cloudOS ProductVersion unknown")
            }
        }

        let tool = Record.Tool(
            buildCommit: environment.buildCommit.map(Record.Known.known) ?? .unknown("build commit not embedded in the executable"),
            executableSHA256: environment.executable.map(Self.sha256Known) ?? .unknown("executable path unknown"),
            swiftCompiler: Self.swiftCompiler,
            hostOS: .known(ProcessInfo.processInfo.operatingSystemVersionString),
            packageResolvedSHA256: environment.sourceRoot.map { Self.sha256Known($0.appendingPathComponent("Package.resolved")) }
                ?? .unknown("no source root"),
            buildDependenciesSHA256: environment.resourcesBase.map {
                Self.sha256Known($0.appendingPathComponent("build-dependencies.json"))
            } ?? .unknown("no resources base"),
            python: python, sealTool: sealTool,
            source: collectSource())

        return .init(tool: tool, firmware: firmware, options: options, inputs: Self.collectInputs(pipeline))
    }

    /// Compile-time compiler version bucket of this build (runtime `swift --version` may differ).
    static var swiftCompiler: Record.Known {
        #if compiler(>=6.3)
        return .known("swift compiler >= 6.3")
        #elseif compiler(>=6.2)
        return .known("swift compiler 6.2")
        #elseif compiler(>=6.1)
        return .known("swift compiler 6.1")
        #else
        return .known("swift compiler 6.0")
        #endif
    }

    static func collectInputs(_ pipeline: FirmwarePipeline) -> Record.Artifacts {
        let restore: URL
        do { restore = try pipeline.findRestoreDirectory() } catch { return .unavailable("no *Restore* directory found in the VM directory") }
        var components: [String: (url: URL, names: [String])] = [:]
        var unresolved: [Record.FileDigest] = []
        func add(_ url: URL, _ name: String) {
            let path = relativePath(url, to: pipeline.vmDirectory)
            components[path, default: (url, [])].names.append(name)
        }
        for component in pipeline.buildComponentList() {
            do {
                add(try pipeline.findFile(in: component.inRestoreDir ? restore : pipeline.vmDirectory,
                                          patterns: component.searchPatterns, label: component.name), component.name)
            } catch {
                unresolved.append(.init(path: "unresolved:\(component.name)", components: [component.name], algorithm: "sha256",
                                        sizeBytes: nil, digest: nil, reason: "\(error)"))
            }
        }
        // Manifests that set gates (base iOS / cloudOS versions).
        for manifest in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
            add(restore.appendingPathComponent(manifest), "gates")
        }
        let files = components.keys.sorted().map { path in
            fileEntry(components[path]!.url, path: path, components: components[path]!.names)
        } + unresolved

        var roots: [Record.FileDigest] = []
        do {
            let componentsByPath = components.mapValues(\.names)
            for root in try pipeline.transactionRoots() {
                let path = relativePath(root, to: pipeline.vmDirectory)
                let names = componentsByPath.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.flatMap(\.value)
                do {
                    roots.append(.init(path: path, components: Array(Set(names)).sorted(), algorithm: Record.treeDigestAlgorithm,
                                       sizeBytes: nil, digest: try FirmwareTransaction.digest(root), reason: nil))
                } catch {
                    roots.append(.init(path: path, components: [], algorithm: Record.treeDigestAlgorithm,
                                       sizeBytes: nil, digest: nil, reason: "\(error)"))
                }
            }
        } catch {
            roots.append(.init(path: "unresolved:roots", components: [], algorithm: Record.treeDigestAlgorithm,
                               sizeBytes: nil, digest: nil, reason: "\(error)"))
        }
        // Reasons must not carry the VM directory's absolute path into the condition digest.
        func scrub(_ entries: [Record.FileDigest]) -> [Record.FileDigest] {
            entries.map { entry in
                var entry = entry
                entry.reason = entry.reason?.replacingOccurrences(of: pipeline.vmDirectory.path, with: "<vm>")
                return entry
            }
        }
        return artifacts(files: scrub(files), roots: scrub(roots.sorted { $0.path < $1.path }))
    }

    // MARK: - Source State

    func collectSource() -> Record.Source {
        let scope = Self.sourceScope
        guard let root = environment.sourceRoot else {
            return .init(status: "unavailable", reason: "no git work tree found above the executable", commit: nil,
                         scope: scope, changes: [], submodules: [])
        }
        do {
            let commit = try git(root, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let submodules = try git(root, ["submodule", "status", "--recursive"]).split(separator: "\n").compactMap { line -> Record.Submodule? in
                guard let first = line.first else { return nil }
                let fields = line.dropFirst().split(separator: " ")
                guard fields.count >= 2 else { return nil }
                return .init(path: String(fields[1]), commit: String(fields[0]), state: first == " " ? "clean" : String(first))
            }
            let changes = try statusChanges(root: root, prefix: "", pathspec: scope, submodules: Set(submodules.map(\.path)))
            return .init(status: changes.isEmpty ? "clean" : "dirty", reason: nil, commit: commit,
                         scope: scope, changes: changes, submodules: submodules)
        } catch {
            return .init(status: "unavailable", reason: "git failed: \(error)", commit: nil, scope: scope, changes: [], submodules: [])
        }
    }

    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"   // status must not refresh the index
        let result = try VPhoneProcessRunner.runCapturing(environment.gitExecutable, ["-C", directory.path] + arguments, env: env)
        guard result.succeeded else {
            throw PatchExperimentRecordError(message: "git \(arguments.joined(separator: " ")) exited \(result.exitCode): \(result.stderr)")
        }
        return result.stdout
    }

    private func statusChanges(root: URL, prefix: String, pathspec: [String], submodules: Set<String>) throws -> [Record.SourceChange] {
        let output = try git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--"] + pathspec)
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var changes: [Record.SourceChange] = []
        while let token = tokens.popFirst() {
            guard token.count > 3 else { continue }
            let code = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            var entries = [(path, code.trimmingCharacters(in: .whitespaces))]
            if code.contains("R") || code.contains("C"), let original = tokens.popFirst() {
                entries.append((original, "renamed-from"))
            }
            for (relative, state) in entries {
                let trimmed = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                let full = prefix + trimmed
                let url = root.appendingPathComponent(trimmed)
                if submodules.contains(full) {
                    let head = (try? git(url, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
                    changes.append(.init(path: full, state: state, sha256: nil, reason: "submodule at HEAD \(head)"))
                    if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                        changes += try statusChanges(root: url, prefix: full + "/", pathspec: [], submodules: submodules)
                    }
                    continue
                }
                changes.append(Self.sourceEntry(url, path: full, state: state))
            }
        }
        return changes.sorted { ($0.path, $0.state) < ($1.path, $1.state) }
    }

    static func sourceEntry(_ url: URL, path: String, state: String) -> Record.SourceChange {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .init(path: path, state: state, sha256: nil, reason: "absent in work tree") }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            if let digest = try? fileSHA256(url) { return .init(path: path, state: state, sha256: digest.sha256, reason: nil) }
            return .init(path: path, state: state, sha256: nil, reason: "unreadable")
        case S_IFLNK:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .init(path: path, state: state, sha256: Record.sha256(Data(target.utf8)), reason: "symlink; sha256 of link target text")
        case S_IFDIR:
            return .init(path: path, state: state, sha256: nil, reason: "directory (nested repository); contents not hashed")
        default:
            return .init(path: path, state: state, sha256: nil, reason: "special file")
        }
    }

    // MARK: - Hashing

    static func relativePath(_ url: URL, to base: URL) -> String {
        let prefix = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func fileSHA256(_ url: URL) throws -> (size: Int, sha256: String) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw PatchExperimentRecordError(message: "not a regular file: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            size += data.count
            return true
        }) {}
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func sha256Known(_ url: URL) -> Record.Known {
        do { return .known(try fileSHA256(url).sha256) } catch { return .unknown("\(url.lastPathComponent): \(error)") }
    }

    static func fileEntry(_ url: URL, path: String, components: [String]) -> Record.FileDigest {
        do {
            let (size, digest) = try fileSHA256(url)
            return .init(path: path, components: components, algorithm: "sha256", sizeBytes: size, digest: digest, reason: nil)
        } catch {
            return .init(path: path, components: components, algorithm: "sha256", sizeBytes: nil, digest: nil, reason: "\(error)")
        }
    }
}
