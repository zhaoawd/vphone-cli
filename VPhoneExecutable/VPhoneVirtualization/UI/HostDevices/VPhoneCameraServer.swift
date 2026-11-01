import CoreGraphics
import Foundation
import Synchronization
import Virtualization

/// Host-side virtual-camera server.
///
/// Opens a vsock connection to the guest on port 1338 (separate from the
/// vphoned control channel on 1337) and pushes raw BGRA frames at a fixed
/// rate. vphoned receives frames on that port and publishes shared memory;
/// the optional libvcamcaptured hook consumes it inside cameracaptured.
///
/// Wire format (one frame, length-prefixed):
///   uint32 LE  total_payload_length
///   uint32 LE  header_json_length
///   bytes      header JSON (UTF-8), keys: w, h, bpr, fmt, ts
///   bytes      raw pixel data, exactly `bpr * h` bytes
///
/// The header carries the format so the receiver doesn't have to
/// assume; for now the producer fixes width/height/bpr/fmt at
/// 1280x720 BGRA. Future producers may emit different formats.
private final class VPhoneCameraGenerationFence: Sendable {
    let token = Atomic<UInt64>(0)
}

@MainActor
final class VPhoneCameraServer {
    enum SourceKind: String {
        case image
        case off
        case testPattern
        case videoFile // .mov / .mp4 / .m4v via AVAssetReader
    }

    nonisolated static let vsockPort: UInt32 = 1338
    nonisolated static let defaultWidth: Int = 1280
    nonisolated static let defaultHeight: Int = 720
    nonisolated static let defaultFPS: Double = 30.0
    nonisolated static let pixelFormat: UInt32 = 0x4247_5241 // 'BGRA' — kCMPixelFormat_32BGRA

    private(set) var sourceKind: SourceKind = .off
    private(set) var isConnected = false

    private var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connectionFD: Int32 = -1
    private var producer: VPhoneFrameProducer?
    private var timer: DispatchSourceTimer?
    private var connectionAttemptToken: UInt64 = 0
    private var framePending = false
    private(set) var currentGeneration = ""
    private(set) var currentRole = "neutral"
    private(set) var presentationID = ""
    private var fps = VPhoneCameraServer.defaultFPS
    private var wireFrameIndex: UInt64 = 0
    private var mayRetainQR = false
    private let fence = VPhoneCameraGenerationFence()

    private let producerQueue = DispatchQueue(
        label: "com.vphone.camera.producer",
        qos: .userInteractive,
    )

    var onConnectionStateChange: ((Bool) -> Void)?

    // MARK: - Lifecycle

    func connect(device: VZVirtioSocketDevice) {
        self.device = device
        attemptConnect()
    }

    func disconnect() {
        connectionAttemptToken &+= 1
        stopStreaming()
        connectionFD = -1
        // Virtualization.framework owns this descriptor and closes it with
        // the connection. Pending frame sends use their own dup.
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
    }

    // MARK: - Source selection

    func setSource(_ kind: SourceKind, videoURL: URL? = nil) {
        if sourceKind == kind, kind != .videoFile {
            return
        }
        let wasStreaming = (timer != nil)
        if wasStreaming {
            stopStreaming()
        }
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        currentGeneration = ""
        presentationID = ""
        sourceKind = kind
        switch kind {
        case .image:
            producer = nil
        case .off:
            producer = nil
        case .testPattern:
            producer = VPhoneTestPatternProducer(
                width: Self.defaultWidth,
                height: Self.defaultHeight,
            )
        case .videoFile:
            guard let url = videoURL else {
                print("[camera] videoFile source requires a URL")
                producer = nil
                sourceKind = .off
                return
            }
            do {
                producer = try VPhoneVideoFileProducer(
                    url: url,
                    width: Self.defaultWidth,
                    height: Self.defaultHeight,
                )
                print("[camera] video file source = \(url.lastPathComponent)")
            } catch {
                print("[camera] failed to open \(url.lastPathComponent): \(error)")
                producer = nil
                sourceKind = .off
            }
        }
        if wasStreaming, producer != nil {
            startStreaming()
        }
    }

    /// Present a still image under a fresh generation/role at a given FPS.
    ///
    /// Returns whether the host source was established and streaming (re)started.
    /// It does NOT prove the guest consumed the frame — the two-level transport
    /// receipt (vphoned published + libvcamcaptured observed) is assembled by the
    /// host-control layer via the guest 1337 `vcam_status` channel, and only that
    /// may report `ok=true` to the caller (invariant #7).
    func present(imagePath: String, generation: String, role: String, fps: Double) -> Bool {
        let producer: VPhoneFrameProducer
        do {
            producer = try VPhoneStillImageProducer(
                url: URL(fileURLWithPath: imagePath),
                width: Self.defaultWidth, height: Self.defaultHeight)
        } catch {
            print("[camera] present: failed to load \(imagePath): \(error)")
            return false
        }
        return beginPresentation(producer, sourceKind: .image,
                                 generation: generation, role: role, fps: fps)
    }

    /// Present a looping video under a fresh generation/role at a given FPS.
    func present(videoPath: String, generation: String, role: String, fps: Double) -> Bool {
        let producer: VPhoneFrameProducer
        do {
            producer = try VPhoneVideoFileProducer(
                url: URL(fileURLWithPath: videoPath),
                width: Self.defaultWidth, height: Self.defaultHeight)
        } catch {
            print("[camera] present: failed to load \(videoPath): \(error)")
            return false
        }
        return beginPresentation(producer, sourceKind: .videoFile,
                                 generation: generation, role: role, fps: fps)
    }

    func presentNeutral(generation: String, fps: Double) -> Bool {
        beginPresentation(VPhoneNeutralFrameProducer(width: Self.defaultWidth, height: Self.defaultHeight),
                          sourceKind: .image, generation: generation, role: "neutral", fps: fps)
    }

    private func beginPresentation(_ producer: any VPhoneFrameProducer,
                                   sourceKind: SourceKind,
                                   generation: String, role: String, fps: Double) -> Bool {
        stopStreaming()
        self.producer = producer
        self.sourceKind = sourceKind
        self.currentGeneration = generation
        self.presentationID = UUID().uuidString
        self.currentRole = role
        if role == "qr" { mayRetainQR = true }
        self.fps = min(30.0, max(1.0, fps))
        self.wireFrameIndex = 0
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        if isConnected { startStreaming() }
        print("[camera] present gen=\(generation) role=\(role) fps=\(self.fps)")
        return isConnected
    }

    /// Stop host production only if `generation` owns the source. The guest
    /// retains its last copied frame; this does not present a neutral image.
    func stop(generation: String) -> Bool {
        guard currentGeneration == generation else { return false }
        stopStreaming()
        producer = nil
        sourceKind = .off
        currentGeneration = ""
        presentationID = ""
        // Preserve unsafe retained QR state until a neutral frame is acknowledged.
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        return true
    }

    /// Host-side publish snapshot for one generation (§8.1). The guest-observed
    /// half is added by the host-control layer from the 1337 `vcam_status` reply.
    func hostStatus(generation: String) -> [String: Any] {
        [
            "source": sourceKind.rawValue,
            "role": sourceKind == .off && mayRetainQR ? "qr" : currentRole,
            "generation": currentGeneration,
            "presentation_id": presentationID,
            "streaming": timer != nil,
            "connected": isConnected,
            // Retain the legacy field; it counts scheduled ticks, not completed writes.
            "host_published_frame_index": Int(wireFrameIndex),
            "host_scheduled_frame_index": Int(wireFrameIndex),
            "host_frame_index_semantics": "scheduled_tick",
            "matches_requested": currentGeneration == generation,
        ]
    }

    func confirmCopied(generation: String, presentationID: String) {
        guard currentGeneration == generation, self.presentationID == presentationID else { return }
        if currentRole == "neutral" { mayRetainQR = false }
    }

    // MARK: - Streaming

    func startStreaming() {
        guard producer != nil, isConnected else { return }
        if timer != nil {
            return
        }
        let interval = 1.0 / fps
        // Timer fires on the main queue so MainActor-isolated state
        // (producer, connectionFD) can be read directly without tripping
        // Swift 6's strict-concurrency isolation check. The frame
        // production + send is then hopped onto producerQueue so
        // BGRA generation doesn't run on the UI thread.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard let producer else { return }
            guard !framePending, connectionFD >= 0 else { return }
            let sourceFD = connectionFD
            let fd = dup(sourceFD)
            guard fd >= 0 else { handleDisconnect(); return }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0
            else {
                close(fd)
                handleDisconnect()
                return
            }
            framePending = true
            let connectionToken = connectionAttemptToken
            let sourceToken = fence.token.load(ordering: .relaxed)
            let fence = self.fence
            let generation = currentGeneration
            let role = currentRole
            let presentationID = self.presentationID
            wireFrameIndex &+= 1
            let frameIndex = wireFrameIndex
            let q = producerQueue
            q.async { [weak self] in
                let frame = producer.nextFrame()
                let current = fence.token.load(ordering: .relaxed) == sourceToken
                let ok = current ? (frame.map { Self.send(fd: fd, frame: $0, generation: generation,
                    role: role, frameIndex: frameIndex, presentationID: presentationID) } ?? true) : true
                close(fd)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    framePending = false
                    if !ok, connectionAttemptToken == connectionToken, connectionFD == sourceFD, fence.token.load(ordering: .relaxed) == sourceToken {
                        handleDisconnect()
                    }
                }
            }
        }
        timer = t
        t.resume()
        print("[camera] streaming started — source=\(sourceKind.rawValue)")
    }

    func stopStreaming() {
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        print("[camera] streaming stopped")
    }

    /// Mark the current connection dead and start reconnecting. Called when
    /// a write fails with EPIPE — the most common case is vphoned auto-update
    /// killing its server-side socket while the host is streaming.
    private func handleDisconnect() {
        print("[camera] disconnect detected, will reconnect")
        connectionFD = -1
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
        // Note: streaming timer continues running but ticks no-op until
        // connectionFD becomes valid again.
        attemptConnect()
    }

    // MARK: - Connect

    private func attemptConnect() {
        guard let device else { return }
        connectionAttemptToken &+= 1
        let attemptToken = connectionAttemptToken
        device.connect(toPort: Self.vsockPort) {
            [weak self] (result: Result<VZVirtioSocketConnection, any Error>) in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionAttemptToken == attemptToken else { return }
                switch result {
                case let .success(conn):
                    self.connection = conn
                    self.connectionFD = conn.fileDescriptor
                    self.isConnected = true
                    print("[camera] connected on vsock port \(Self.vsockPort)")
                    self.onConnectionStateChange?(true)
                    if self.sourceKind != .off {
                        self.startStreaming()
                    }
                case let .failure(error):
                    print("[camera] connect failed: \(error). Retrying in 3s.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            guard self.connectionAttemptToken == attemptToken else { return }
                            self.attemptConnect()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Wire

    @discardableResult
    private nonisolated static func send(fd: Int32, frame: VPhoneCameraFrame, generation: String = "", role: String = "test", frameIndex: UInt64 = 0, presentationID: String = "") -> Bool {
        // header
        let headerDict: [String: Any] = [
            "w": frame.width,
            "h": frame.height,
            "bpr": frame.bytesPerRow,
            "fmt": Self.pixelFormat,
            "ts": frame.timestampNS,
            "gen": generation, "role": role, "fi": frameIndex, "presentation_id": presentationID,
        ]
        guard
            let headerData = try? JSONSerialization.data(withJSONObject: headerDict, options: [])
        else { return false }
        let totalLen = UInt32(4 + headerData.count + frame.pixels.count)
        let headerLen = UInt32(headerData.count)
        var prefix = Data()
        prefix.append(contentsOf: withUnsafeBytes(of: totalLen.littleEndian) { Array($0) })
        prefix.append(contentsOf: withUnsafeBytes(of: headerLen.littleEndian) { Array($0) })
        // Concat all into one buffer to make a single write — short frames
        // are cheap; large ones (1280*720*4 ≈ 3.5 MB) still fit comfortably
        // in a vsock send buffer and a single write keeps frame integrity
        // even if a future reader uses non-buffered I/O.
        var out = Data(capacity: Int(totalLen) + 4)
        out.append(prefix)
        out.append(headerData)
        out.append(frame.pixels)
        var ok = true
        out.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { ok = false; return }
            var remaining = bytes.count
            var cursor = base
            while remaining > 0 {
                let n = write(fd, cursor, remaining)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    print("[camera] write errno=\(errno)")
                    ok = false
                    return
                }
                if n == 0 {
                    ok = false; return
                }
                remaining -= n
                cursor = cursor.advanced(by: n)
            }
        }
        return ok
    }
}
