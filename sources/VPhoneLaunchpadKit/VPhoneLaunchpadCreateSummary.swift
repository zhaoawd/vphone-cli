import Foundation
import VPhoneCore

/// The inspector's summary of a machine's `vm create` checkpoint.
///
/// Read with `VPhoneCreateCheckpointStore.load(bundleURL:)`, which takes no
/// lock; the CLI writes the file as a temporary file plus rename. Statuses
/// keep their checkpoint spelling (`unverified`, `completed_unverified`,
/// `recovery_required`, ...), so nothing reads as passed that the checkpoint
/// does not record as passed. The overall status comes from the stored
/// stages alone: a create that is still running reads as `interrupted`.
public struct VPhoneLaunchpadCreateSummary: Equatable, Sendable {
    public struct Stage: Equatable, Sendable {
        public let name: String
        public let status: String
    }

    public let variant: String
    public let overallStatus: String
    public let nextStage: String?
    public let updatedAt: Date
    public let stages: [Stage]
    /// `recoveryRequired.detail`, when the checkpoint records one.
    public let recovery: String?

    init(_ checkpoint: VPhoneCreateCheckpoint) {
        variant = checkpoint.effectiveOptions.variant
        overallStatus = checkpoint.overallStatus.rawValue
        nextStage = checkpoint.nextStage?.rawValue
        updatedAt = checkpoint.updatedAt
        stages = checkpoint.stages.map { Stage(name: $0.stage.rawValue, status: $0.status.rawValue) }
        recovery = checkpoint.recoveryRequired?.detail
    }

    /// Nil when the machine has no checkpoint (created by `vm new`, or by a
    /// create that predates checkpoints); otherwise the summary, or why the
    /// file could not be read.
    public static func read(_ machine: VPhoneLaunchpadMachinePath) -> Result<VPhoneLaunchpadCreateSummary, VPhoneLaunchpadError>? {
        do {
            return .success(VPhoneLaunchpadCreateSummary(try VPhoneCreateCheckpointStore.load(bundleURL: machine.url).checkpoint))
        } catch VPhoneCreateCheckpointError.missing {
            return nil
        } catch {
            return .failure(VPhoneLaunchpadError(String(describing: error)))
        }
    }
}
