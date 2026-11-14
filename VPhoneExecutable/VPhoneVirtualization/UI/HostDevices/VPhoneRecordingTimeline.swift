import CoreMedia

/// Movie timestamps retain elapsed capture time even when the recorder skips
/// samples. The first successfully written sample starts the movie at zero.
struct VPhoneRecordingTimeline {
    private(set) var firstCaptureUptimeNanoseconds: UInt64?
    private var last: UInt64?

    func presentationTime(for capturedAt: UInt64) -> CMTime? {
        if let last, capturedAt <= last { return nil }
        guard let first = firstCaptureUptimeNanoseconds else { return .zero }
        guard let elapsed = Int64(exactly: capturedAt - first) else { return nil }
        return CMTime(value: elapsed, timescale: 1_000_000_000)
    }

    mutating func didAppend(at capturedAt: UInt64) {
        if firstCaptureUptimeNanoseconds == nil { firstCaptureUptimeNanoseconds = capturedAt }
        last = capturedAt
    }
}
