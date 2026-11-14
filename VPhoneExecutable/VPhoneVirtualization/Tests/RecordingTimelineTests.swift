import AVFoundation
import CoreVideo

@main
enum RecordingTimelineTests {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--clock" {
            print(DispatchTime.now().uptimeNanoseconds)
            return
        }
        var timeline = VPhoneRecordingTimeline()
        // An unaccepted capture must not establish the origin.
        precondition(timeline.presentationTime(for: 100) == .zero)
        precondition(timeline.firstCaptureUptimeNanoseconds == nil)
        let origin: UInt64 = 5_000_000_000
        let offsets: [UInt64] = [0, 40_000_000, 360_000_000, 400_000_000]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for offset in offsets {
            let captured = origin + offset
            guard let pts = timeline.presentationTime(for: captured) else { fatalError("Missing timestamp") }
            precondition(abs(pts.seconds - Double(offset) / 1e9) < 0.000_001)
            let deadline = ContinuousClock.now + .seconds(3)
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            precondition(status == kCVReturnSuccess)
            guard let buffer else { fatalError("Missing pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adaptor.append(buffer, withPresentationTime: pts))
            timeline.didAppend(at: captured)
            precondition(timeline.firstCaptureUptimeNanoseconds == origin)
            precondition(timeline.presentationTime(for: captured) == nil)
            precondition(timeline.presentationTime(for: captured - 1) == nil)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
