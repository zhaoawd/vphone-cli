import Foundation
import Observation
import VPhoneCore

// MARK: - Progress

/// A create checkpoint as the creation view shows it. Read with
/// `VPhoneCreateCheckpointStore.load(bundleURL:)`, which takes no lock; the
/// CLI writes the file as a temporary file plus rename.
///
/// Statuses keep their checkpoint spelling. The tone only picks the icon:
/// nothing but `succeeded` reads as passed, so `unverified`,
/// `completed_unverified` and `recovery_required` never look like success.
public struct VPhoneLaunchpadCreateProgress: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        case passed
        case warning
        case failed
        case pending
        case running
        case notApplicable
    }

    public struct Stage: Equatable, Identifiable, Sendable {
        public let stage: VPhoneCreateStage
        /// The checkpoint spelling: `pending`, `running`, `succeeded`,
        /// `unverified`, `failed`, `cancelled`, `not_applicable`.
        public let status: String
        public let tone: Tone
        /// `reason` (why unverified or not applicable) or `error`.
        public let note: String?
        public let startedAt: Date?
        public let finishedAt: Date?
        /// Earlier attempts of this stage kept in the checkpoint.
        public let earlierAttempts: Int

        public var id: String {
            stage.rawValue
        }

        public var name: String {
            stage.rawValue
        }
    }

    public struct Recovery: Equatable, Sendable {
        public let kind: String
        public let stage: String?
        public let detail: String
        public let action: String
    }

    public let variant: String
    /// `running` while Launchpad's own create run is alive (as
    /// `vm create-status` reports a held run lock); otherwise the overall
    /// status the checkpoint's stages give.
    public let overallStatus: String
    public let overallTone: Tone
    public let nextStage: VPhoneCreateStage?
    public let updatedAt: Date
    public let stages: [Stage]
    public let recovery: Recovery?
    /// The toolchain digest recorded by the last create or resume.
    public let toolchainSha256: String?
    public let attempts: Int

    /// `live`: Launchpad's own `vm create` child for this machine has not
    /// exited. Without it, a stage left `running` means its process ended
    /// (the checkpoint reads `interrupted`); with it, the stage is under way.
    public init(_ checkpoint: VPhoneCreateCheckpoint, live: Bool) {
        variant = checkpoint.effectiveOptions.variant
        let overall = checkpoint.overallStatus
        overallStatus = live ? "running" : overall.rawValue
        overallTone = live ? .running : Self.tone(overall)
        nextStage = checkpoint.nextStage
        updatedAt = checkpoint.updatedAt
        stages = checkpoint.stages.map { record in
            Stage(
                stage: record.stage, status: record.status.rawValue, tone: Self.tone(record.status, live: live),
                note: record.error ?? record.reason, startedAt: record.startedAt, finishedAt: record.finishedAt,
                earlierAttempts: record.history.count)
        }
        recovery = checkpoint.recoveryRequired.map {
            Recovery(kind: $0.kind, stage: $0.stage?.rawValue, detail: $0.detail, action: $0.action)
        }
        toolchainSha256 = checkpoint.tool.executableSha256
        attempts = checkpoint.attempts.count
    }

    public static func tone(_ status: VPhoneCreateStageStatus, live: Bool) -> Tone {
        switch status {
        case .succeeded: .passed
        case .unverified: .warning
        case .notApplicable: .notApplicable
        case .pending: .pending
        case .running: live ? .running : .warning
        case .cancelled: .warning
        case .failed: .failed
        }
    }

    public static func tone(_ overall: VPhoneCreateOverallStatus) -> Tone {
        switch overall {
        case .succeeded: .passed
        case .completedUnverified, .interrupted, .cancelled: .warning
        case .incomplete: .pending
        case .failed, .recoveryRequired: .failed
        }
    }

    /// True when a resume has something to run: an unfinished stage, or a
    /// recovery requirement recorded by the last attempt.
    public var hasNextStage: Bool {
        nextStage != nil
    }

    /// Stages `--restart-from` accepts: up to the next unfinished one, or
    /// any stage once every stage is done (`VPhoneCreateRunner.resume`).
    public var restartableStages: [VPhoneCreateStage] {
        let last = nextStage ?? VPhoneCreateStage.allCases.last!
        return VPhoneCreateStage.allCases.filter { $0 <= last }
    }

    /// Reads a machine's checkpoint. Nil when there is none.
    public static func read(_ machine: VPhoneLaunchpadMachinePath, live: Bool) -> Result<Self, VPhoneLaunchpadError>? {
        do {
            return .success(Self(try VPhoneCreateCheckpointStore.load(bundleURL: machine.url).checkpoint, live: live))
        } catch VPhoneCreateCheckpointError.missing {
            return nil
        } catch {
            return .failure(VPhoneLaunchpadError(String(describing: error)))
        }
    }
}

// MARK: - create-status

/// The part of `vm create-status --json` Launchpad shows after a create run
/// has exited (snake_case keys, `VPhoneCreateJSON`).
public struct VPhoneLaunchpadCreateStatus: Decodable, Equatable, Sendable {
    public struct Live: Decodable, Equatable, Sendable {
        public let createRunInProgress: Bool
        public let bundleLockHeld: Bool
        public let firmwareTransaction: VPhoneCreateRecoveryRequirement?
    }

    public let overallStatus: String?
    public let checkpointError: String?
    public let nextStage: String?
    public let live: Live

    public static func decode(_ result: VPhoneLaunchpadCommandResult) throws -> Self {
        // Exit 2 still prints the report, with `checkpoint_error`.
        guard result.status == 0 || result.status == 2, let data = result.jsonData else {
            throw VPhoneLaunchpadError(String(localized: "Unable to read the create status."), detail: result.tail)
        }
        return try VPhoneCreateJSON.decoder.decode(Self.self, from: data)
    }
}

// MARK: - Tool change

/// A resume refused because the toolchain digest differs from the one the
/// checkpoint records. The CLI prints both in its `Error:` line:
/// `CLI/VM toolchain changed since the checkpoint (<recorded> -> <current>); pass --accept-tool-change ...`.
public struct VPhoneLaunchpadToolChange: Equatable, Sendable {
    public let recorded: String
    public let current: String

    public static func parse(_ lines: [String]) -> Self? {
        let pattern = #"toolchain changed since the checkpoint \(([^ ]+) -> ([^)]+)\)"#
        for line in lines.reversed() {
            guard let match = line.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let inner = line[match].dropFirst("toolchain changed since the checkpoint (".count).dropLast()
            let parts = inner.components(separatedBy: " -> ")
            guard parts.count == 2 else {
                continue
            }
            return Self(recorded: parts[0], current: parts[1])
        }
        return nil
    }
}

// MARK: - Creation

/// One machine's `vm create` or `vm create --resume` run, started by this
/// Launchpad, and the checkpoint it writes.
///
/// The child runs detached in its own session (process group) and writes
/// `<logs>/<name>[-<digest>]-create.log`. While it runs, the checkpoint is
/// read every second without a lock. `vm create-status` runs once, after
/// the child has exited. Cancel sends SIGINT to the child's process group.
@MainActor
@Observable
public final class VPhoneLaunchpadCreation {
    public static let pollInterval: Duration = .seconds(1)

    public let machine: VPhoneLaunchpadMachinePath
    public let logFile: URL
    /// The command last started, for the history and the (i) button.
    public private(set) var command: VPhoneLaunchpadCreateCommand?
    public private(set) var progress: Result<VPhoneLaunchpadCreateProgress, VPhoneLaunchpadError>?
    public private(set) var startedAt: Date?
    public private(set) var exitStatus: Int32?
    /// The last lines the run printed, shown when it fails.
    public private(set) var outputTail: [String] = []
    public private(set) var status: Result<VPhoneLaunchpadCreateStatus, VPhoneLaunchpadError>?
    /// Set when the last resume was refused for a changed toolchain; the
    /// creation view asks before resuming with `--accept-tool-change`.
    public private(set) var toolChange: VPhoneLaunchpadToolChange?
    public private(set) var cancelRequested = false
    public var startError: VPhoneLaunchpadError?
    /// What the last resume asked for, reused when a tool change is accepted.
    public private(set) var lastResume: (restartFrom: VPhoneCreateStage?, keepArtifacts: Bool)?

    @ObservationIgnored private var child: VPhoneLaunchpadChildProcess?
    @ObservationIgnored var onFinish: (() async -> Void)?

    init(machine: VPhoneLaunchpadMachinePath, logFile: URL) {
        self.machine = machine
        self.logFile = logFile
    }

    public var isRunning: Bool {
        child?.isRunning == true
    }

    /// The child's PID, which is also its process group ID, while it runs.
    public var processGroup: pid_t? {
        isRunning ? child?.processIdentifier : nil
    }

    /// Reads the checkpoint once, off the main actor.
    public func reloadProgress() async {
        let machine = machine
        let live = isRunning
        progress = await Task.detached { VPhoneLaunchpadCreateProgress.read(machine, live: live) }.value
    }

    // MARK: Run

    func start(_ command: VPhoneLaunchpadCreateCommand, with commandLine: VPhoneLaunchpadCommandLine) {
        guard !isRunning else {
            return
        }
        self.command = command
        exitStatus = nil
        status = nil
        toolChange = nil
        cancelRequested = false
        startError = nil
        outputTail = []
        let appending = command.kind == .resume
        if appending {
            VPhoneLaunchpadConsoleLog.append("=== \(Date().formatted(.iso8601)) \(command.display) ===", to: logFile)
        }
        let collector = VPhoneLaunchpadLineCollector()
        do {
            let child = try commandLine.start(command, logFile: logFile, appendingToLog: appending) { line in
                collector.append(line)
            }
            self.child = child
            startedAt = Date()
            VPhoneLaunchpadMachineLibrary.diagnostic("vm create started, pid \(child.processIdentifier)")
            Task { [weak self] in
                await self?.follow(child, commandLine: commandLine, collector: collector)
            }
        } catch {
            startError = VPhoneLaunchpadError(
                String(localized: "Unable to Create \(machine.name)"), detail: error.localizedDescription)
        }
    }

    /// The user declined to resume with the changed toolchain.
    public func dismissToolChange() {
        toolChange = nil
    }

    func noteResume(restartFrom: VPhoneCreateStage?, keepArtifacts: Bool) {
        lastResume = (restartFrom, keepArtifacts)
    }

    /// Reads the checkpoint every second while the child runs, then once
    /// more, then runs `vm create-status` once.
    private func follow(
        _ child: VPhoneLaunchpadChildProcess, commandLine: VPhoneLaunchpadCommandLine,
        collector: VPhoneLaunchpadLineCollector
    ) async {
        let waiter = Task { await child.wait() }
        while child.isRunning {
            await reloadProgress()
            try? await Task.sleep(for: Self.pollInterval)
        }
        let code = await waiter.value
        exitStatus = code
        outputTail = Array(collector.lines.suffix(20))
        VPhoneLaunchpadMachineLibrary.diagnostic("vm create pid \(child.processIdentifier) exited with status \(code)")
        await reloadProgress()
        if code != 0, command?.kind == .resume {
            toolChange = VPhoneLaunchpadToolChange.parse(collector.lines)
        }
        if let status = VPhoneLaunchpadCreateCommand.status(machine) {
            do {
                self.status = .success(try VPhoneLaunchpadCreateStatus.decode(try await commandLine.run(status)))
            } catch let error as VPhoneLaunchpadError {
                self.status = .failure(error)
            } catch {
                self.status = .failure(VPhoneLaunchpadError(error.localizedDescription))
            }
        }
        await onFinish?()
    }

    /// SIGINT to the run's process group. `vm create` has no SIGINT handler
    /// and ends; the stage it was running stays `running` in the checkpoint,
    /// which then reads `interrupted`. False when nothing was sent.
    @discardableResult
    public func cancel() -> Bool {
        guard let child, child.isRunning else {
            return false
        }
        cancelRequested = true
        VPhoneLaunchpadMachineLibrary.diagnostic("vm create pid \(child.processIdentifier): SIGINT to its process group")
        return child.interruptGroup()
    }
}

// MARK: - Library

public extension VPhoneLaunchpadMachineLibrary {
    /// True while a `vm create` this Launchpad started is still running.
    var hasActiveCreation: Bool {
        creations.values.contains { $0.isRunning }
    }

    /// The machine's creation entry, made on first use so a checkpoint can be
    /// shown and resumed for a machine this Launchpad did not create.
    func creation(for machine: Path) -> VPhoneLaunchpadCreation {
        if let creation = creations[machine] {
            return creation
        }
        let creation = VPhoneLaunchpadCreation(
            machine: machine, logFile: consoleLog(machine, suffix: "-create"))
        creation.onFinish = { [weak self] in
            await self?.refresh()
        }
        creations[machine] = creation
        return creation
    }

    /// True when New Machine may use `name` in `root`: not listed, not being
    /// created, and no folder of that name.
    func isTaken(_ machine: Path) -> Bool {
        machines.contains { $0.path == machine } || creations[machine]?.isRunning == true
            || VPhoneLaunchpadExportOutput.exists(machine.url)
    }

    /// Starts `vm create` for a new machine and selects it. Nil when the
    /// request cannot be passed, or the name is taken.
    @discardableResult
    func create(_ request: VPhoneLaunchpadCreateRequest) -> VPhoneLaunchpadCreation? {
        guard let commandLine = currentCommandLine, let command = VPhoneLaunchpadCreateCommand.create(request),
              !isTaken(request.machine)
        else {
            return nil
        }
        let creation = creation(for: request.machine)
        creation.start(command, with: commandLine)
        selection = [request.machine]
        return creation
    }

    /// True when `vm create --resume` may start: the toolchain is verified,
    /// nothing else is under way for the machine, it is stopped as far as
    /// the process list shows, and its checkpoint names a variant Launchpad
    /// offers.
    func canResume(_ machine: Path) -> Bool {
        guard canStart(machine), case let .success(progress)? = creations[machine]?.progress else {
            return false
        }
        return VPhoneLaunchpadCreateVariant(rawValue: progress.variant)?.isAvailable == true
    }

    /// `vm create <name> --resume [--restart-from] [--accept-tool-change]`.
    /// `acceptToolChange` is passed only from the confirmation that lists
    /// the recorded and current toolchain digests.
    func resume(
        _ machine: Path, restartFrom: VPhoneCreateStage? = nil, acceptToolChange: Bool = false,
        keepArtifacts: Bool = false
    ) {
        guard let commandLine = currentCommandLine, canResume(machine),
              case let .success(progress)? = creations[machine]?.progress,
              let command = VPhoneLaunchpadCreateCommand.resume(
                  machine, variant: progress.variant, restartFrom: restartFrom,
                  acceptToolChange: acceptToolChange, keepArtifacts: keepArtifacts)
        else {
            return
        }
        let creation = creation(for: machine)
        creation.noteResume(restartFrom: restartFrom, keepArtifacts: keepArtifacts)
        creation.start(command, with: commandLine)
    }

    /// Cancels every create run this Launchpad started (quitting).
    func cancelAllCreations() {
        for creation in creations.values where creation.isRunning {
            creation.cancel()
        }
    }
}

// MARK: - Quitting

/// What quitting does while a create run is under way. The run would
/// survive Launchpad (its own session), with nobody to show or cancel it,
/// so quitting asks first and, when confirmed, cancels it.
public enum VPhoneLaunchpadQuit {
    public enum Decision: Equatable, Sendable {
        case quit
        case confirm(machines: [String])
    }

    @MainActor
    public static func decision(_ library: VPhoneLaunchpadMachineLibrary) -> Decision {
        let running = library.creations.values.filter(\.isRunning).map(\.machine.name).sorted()
        return running.isEmpty ? .quit : .confirm(machines: running)
    }

    /// The user confirmed: SIGINT to every create run's process group.
    @MainActor
    public static func confirmed(_ library: VPhoneLaunchpadMachineLibrary) {
        library.cancelAllCreations()
    }
}
