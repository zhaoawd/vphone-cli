import CoreGraphics
import Foundation
import Synchronization
import Virtualization

/// Sendable holder for the generation fence counter. `Atomic` is non-copyable,
/// so it can't be bound into the producer-queue closure directly; capturing this
/// reference lets both the MainActor timer and the send queue read it in place.
private final class VPhoneGenerationFence: Sendable {
    let token = Atomic<UInt64>(0)
}

/// Host-side virtual-camera server.
///
/// Opens a vsock connection to the guest on port 1338 (separate from the
/// vphoned control channel on 1337) and pushes raw BGRA frames at a fixed
/// rate. The guest counterpart (a libvcamcaptured-attached receiver inside
/// cameracaptured) ferries those frames into the AVF capture pipeline.
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
@MainActor
final class VPhoneCameraServer {
    enum SourceKind: String {
        case off
        case testPattern
        case videoFile  // .mov / .mp4 / .m4v via AVAssetReader
        case image      // .png / .jpeg still (QR / neutral) via VPhoneStillImageProducer
    }

    nonisolated static let vsockPort: UInt32 = 1338
    nonisolated static let defaultWidth: Int = 1280
    nonisolated static let defaultHeight: Int = 720
    nonisolated static let defaultFPS: Double = 30.0
    nonisolated static let pixelFormat: UInt32 = 0x4247_5241  // 'BGRA' — kCMPixelFormat_32BGRA

    private(set) var sourceKind: SourceKind = .off
    private(set) var isConnected = false

    // Protocol v2 generation/role (§8.3). `currentGeneration` binds the wire
    // frames to one QrArtifact/neutral request; `generationToken` fences the
    // producer queue so a frame scheduled before a source switch is dropped
    // instead of leaking a stale QR into the next generation.
    private(set) var currentGeneration: String = ""
    private(set) var currentRole: String = "neutral"
    private var fps: Double = VPhoneCameraServer.defaultFPS
    private var wireFrameIndex: UInt64 = 0
    private let fence = VPhoneGenerationFence()

    private var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connectionFD: Int32 = -1
    private var producer: VPhoneFrameProducer?
    private var timer: DispatchSourceTimer?
    private var connectionAttemptToken: UInt64 = 0

    private let sendQueue = DispatchQueue(
        label: "com.vphone.camera.send", qos: .userInteractive)
    private let producerQueue = DispatchQueue(
        label: "com.vphone.camera.producer", qos: .userInteractive)

    var onConnectionStateChange: ((Bool) -> Void)?

    // MARK: - Lifecycle

    func connect(device: VZVirtioSocketDevice) {
        self.device = device
        attemptConnect()
    }

    func disconnect() {
        stopStreaming()
        if connectionFD >= 0 {
            close(connectionFD)
            connectionFD = -1
        }
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
    }

    // MARK: - Source selection

    func setSource(_ kind: SourceKind, videoURL: URL? = nil) {
        if sourceKind == kind, kind != .videoFile { return }
        let wasStreaming = (timer != nil)
        if wasStreaming { stopStreaming() }
        sourceKind = kind
        switch kind {
        case .off:
            producer = nil
        case .testPattern:
            producer = VPhoneTestPatternProducer(
                width: Self.defaultWidth,
                height: Self.defaultHeight)
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
                    height: Self.defaultHeight)
                print("[camera] video file source = \(url.lastPathComponent)")
            } catch {
                print("[camera] failed to open \(url.lastPathComponent): \(error)")
                producer = nil
                sourceKind = .off
            }
        case .image:
            // The still/QR source is driven by present(imagePath:…), which sets
            // the producer directly; the menu setSource path can't build one
            // without a path, so treat it as a no-op source.
            producer = nil
            sourceKind = .off
        }
        if wasStreaming, producer != nil {
            startStreaming()
        }
    }

    // MARK: - Automation face (§8.1): present / stop / status

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
        stopStreaming()
        self.producer = producer
        self.sourceKind = .image
        self.currentGeneration = generation
        self.currentRole = role
        self.fps = min(30.0, max(1.0, fps))
        self.wireFrameIndex = 0
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        if isConnected { startStreaming() }
        print("[camera] present gen=\(generation) role=\(role) fps=\(self.fps)")
        return isConnected
    }

    /// Stop only if `generation` owns the current source; otherwise a conflict.
    func stop(generation: String) -> Bool {
        guard currentGeneration == generation else { return false }
        stopStreaming()
        producer = nil
        sourceKind = .off
        currentGeneration = ""
        currentRole = "neutral"
        _ = fence.token.wrappingAdd(1, ordering: .relaxed)
        return true
    }

    /// Host-side publish snapshot for one generation (§8.1). The guest-observed
    /// half is added by the host-control layer from the 1337 `vcam_status` reply.
    func hostStatus(generation: String) -> [String: Any] {
        [
            "source": sourceKind.rawValue,
            "role": currentRole,
            "generation": currentGeneration,
            "streaming": timer != nil,
            "connected": isConnected,
            "host_published_frame_index": Int(wireFrameIndex),
            "matches_requested": currentGeneration == generation,
        ]
    }

    // MARK: - Streaming

    func startStreaming() {
        guard producer != nil, isConnected else { return }
        if timer != nil { return }
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
            guard let producer = self.producer else { return }
            let fd = self.connectionFD
            guard fd >= 0 else { return }
            self.wireFrameIndex &+= 1
            let fi = self.wireFrameIndex
            let gen = self.currentGeneration
            let role = self.currentRole
            let fence = self.fence
            let tokenSnapshot = fence.token.load(ordering: .relaxed)
            let q = self.producerQueue
            q.async {
                // Generation fence (§8.3): if a source/generation switch landed
                // after this tick was scheduled, drop the stale frame rather
                // than send an old QR under a new generation.
                if fence.token.load(ordering: .relaxed) != tokenSnapshot { return }
                guard let frame = producer.nextFrame() else { return }
                let ok = Self.send(fd: fd, frame: frame,
                                   generation: gen, role: role, frameIndex: fi)
                if !ok {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Avoid double-handling if a parallel write already
                        // dropped the connection.
                        if self.connectionFD == fd {
                            self.handleDisconnect()
                        }
                    }
                }
            }
        }
        timer = t
        t.resume()
        print("[camera] streaming started — source=\(sourceKind.rawValue)")
    }

    func stopStreaming() {
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
        let oldFD = connectionFD
        connectionFD = -1
        connection = nil
        if isConnected {
            isConnected = false
            onConnectionStateChange?(false)
        }
        if oldFD >= 0 { close(oldFD) }
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
                    if self.sourceKind != .off { self.startStreaming() }
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
    nonisolated private static func send(
        fd: Int32, frame: VPhoneCameraFrame,
        generation: String = "", role: String = "test", frameIndex: UInt64 = 0
    ) -> Bool {
        // header — protocol v2 adds pv/gen/role/fi (§8.3). The guest reader
        // ignores unknown keys, so a v1 receiver stays compatible.
        let headerDict: [String: Any] = [
            "w": frame.width,
            "h": frame.height,
            "bpr": frame.bytesPerRow,
            "fmt": Self.pixelFormat,
            "ts": frame.timestampNS,
            "pv": 2,
            "gen": generation,
            "role": role,
            "fi": frameIndex,
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
        out.withUnsafeBytes { bytes -> Void in
            guard let base = bytes.baseAddress else { ok = false; return }
            var remaining = bytes.count
            var cursor = base
            while remaining > 0 {
                let n = write(fd, cursor, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    print("[camera] write errno=\(errno)")
                    ok = false
                    return
                }
                if n == 0 { ok = false; return }
                remaining -= n
                cursor = cursor.advanced(by: n)
            }
        }
        return ok
    }
}
