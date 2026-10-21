import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - rebase

/// `vm rebase`: re-share a stopped machine's disk image with another's.
struct VPhoneVMRebaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rebase",
        abstract: "Re-share identical disk blocks with another stopped VM",
        discussion: """
        Both VMs must be stopped on one APFS volume. The target's logical bytes,
        SEP storage, NVRAM and identity are preserved. Newly shared bytes exclude
        blocks already shared. Snapshots and other clones can retain old blocks.
        Disk inode replacement invalidates inode-bound firmware qualification;
        existing Receipt/generation records are preserved without new authority.
        --dry-run only compares. --recover completes a pending verified exchange.
        """)

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM whose disk image is rebased") var name: String?
    @Option(name: .long, help: "Stopped VM used as the disk block source") var onto: String?
    @Flag(help: "Compare without replacing the disk") var dryRun = false
    @Flag(help: "Recover this VM's pending rebase without reconstructing blocks") var recover = false

    func validate() throws {
        guard recover ? (onto == nil && !dryRun) : onto != nil else {
            throw ValidationError("Use --onto <vm> [--dry-run], or --recover")
        }
        for value in [name, onto].compactMap({ $0 }) {
            guard VPhoneVirtualMachineManifest.isPlainFileName(value), !value.hasPrefix(".") else {
                throw ValidationError("Rebase requires VM names from the selected library")
            }
        }
    }

    private func bundle(named name: String) throws -> VPhoneBundle {
        let bundle = try lib.library.bundle(named: name)
        let root = lib.library.root.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == root else {
            throw ValidationError("Rebase VM resolves outside the selected library")
        }
        return bundle
    }

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let target = try bundle(named: name)
        if recover {
            try VPhoneDiskRebase.recover(target)
            print("Rebase recovery complete for \(target.name)")
            return
        }
        guard let onto else { throw ValidationError("--onto is required") }
        let base = try bundle(named: onto)
        let cancellation = VPhoneChildCancellation(log: { _ in })
        cancellation.install()
        defer { cancellation.complete(); cancellation.uninstall() }
        do {
            let clock = ContinuousClock()
            let start = clock.now
            var bar: VPhoneProgressBar?
            var phase: VPhoneDiskRebase.Phase?
            let progress: VPhoneDiskRebase.Progress = { current, done, total in
                if current != phase {
                    bar?.finish()
                    phase = current
                    bar = VPhoneProgressBar(label: current == .comparing ? "comparing" : "verifying")
                }
                bar?.update(done: done, total: total)
            }
            let report = dryRun
                ? try VPhoneDiskRebase.plan(target, onto: base, isCancelled: { cancellation.isRequested }, progress: progress)
                : try VPhoneDiskRebase.rebase(target, onto: base, isCancelled: { cancellation.isRequested }, progress: progress)
            bar?.finish()
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

            let elapsedText = VPhoneProgressBar.clock(seconds)
            let saving = Self.gigabytes(report.newlySharedBytes)
            if dryRun {
                print("dry run: \(saving) would be newly shared with \(base.name); compared \(target.name) in \(elapsedText), disk bytes were not changed")
            } else {
                print("rebased \(target.name) onto \(base.name) in \(elapsedText); \(saving) newly shared")
            }
            for line in Self.describe(report, base: base.name, dryRun: dryRun) {
                print("  " + line)
            }
            if let note = Self.savingNote(report, target: target.name, base: base.name, dryRun: dryRun) {
                print("note: " + note)
            }
            if !dryRun, let snapshots = try? VPhoneMachineSnapshots.list(of: target), !snapshots.isEmpty {
                print("note: \(target.name) has \(snapshots.count) snapshot(s), which keep the old image's blocks until deleted")
            }
        } catch {
            if let signal = cancellation.requestedSignal {
                cancellation.settle()
                throw ExitCode(128 + signal)
            }
            throw error
        }
    }

    /// The report as aligned lines, in decimal gigabytes like disk sizes.
    static func describe(_ report: VPhoneDiskRebaseReport, base: String, dryRun: Bool) -> [String] {
        let rows: [(String, Int64, String)] = [
            ("disk image", report.logicalSize, "logical size; \(gigabytes(report.comparedBytes)) holds data in either image"),
            ("newly shared", report.newlySharedBytes, dryRun
                ? "identical to \(base) at the same offset, would be shared"
                : "identical to \(base) at the same offset, now shared"),
            ("already shared", report.alreadySharedBytes, "identical, and already the same blocks on disk (or a hole): frees nothing"),
            ("written", report.writtenBytes, dryRun ? "differs from \(base), would be written" : "differs from \(base), written"),
            ("punched", report.punchedBytes, dryRun ? "zeros where \(base) has data, would become holes" : "zeros where \(base) has data, now holes"),
        ]
        let sizes = rows.map { gigabytes($0.1) }
        let width = sizes.map(\.count).max() ?? 0
        return zip(rows, sizes).map { row, size in
            row.0.padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(repeating: " ", count: width - size.count) + size + "  " + row.2
        }
    }

    /// Below this, the rebase is reported as freeing almost nothing.
    static let negligibleSaving: Int64 = 100_000_000

    /// Why a rebase that newly shares almost nothing is not worth it.
    static func savingNote(_ report: VPhoneDiskRebaseReport, target: String, base: String, dryRun: Bool) -> String? {
        guard report.newlySharedBytes < negligibleSaving else { return nil }
        let frees = dryRun ? "the rebase would free almost nothing" : "few bytes were newly shared; actual free space depends on retained snapshots and clones"
        if report.alreadySharedBytes > report.newlySharedBytes {
            return "\(frees): \(target) already shares its identical blocks with \(base) on disk"
        }
        return "\(frees): \(target) has few blocks identical to \(base)"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1e9)
    }
}
