import CryptoKit
import Foundation
import Virtualization
import VPhoneCore

/// Host-side client for the vphoned guest agent.
///
/// Communicates over vsock using length-prefixed JSON (vphone-control protocol).
/// Each message is `[uint32 big-endian length][UTF-8 JSON]` where JSON
/// always carries `"v"` (protocol version), `"t"` (message type), and
/// optionally `"id"` (request ID, echoed in responses).
///
/// Auto-update: if `guestBinaryURL` is set, the hello message includes
/// its SHA-256 hash. When the guest replies with `need_update`, we push
/// the binary as a raw transfer (`{"t":"update","size":N}` + N bytes).
@MainActor
class VPhoneControl {
    private static let protocolVersion = 1
    private static let vsockPort: UInt32 = 1337
    private static let reconnectDelay: TimeInterval = 3
    private static let defaultRequestTimeout: TimeInterval = 10
    private static let slowRequestTimeout: TimeInterval = 30
    private static let transferRequestTimeout: TimeInterval = 180
    private static let heartbeatInterval: TimeInterval = 15

    private var connection: VZVirtioSocketConnection?
    private var channel: VPhoneControlChannel?

    struct Timing: Sendable {
        var handshake: TimeInterval = 8
        var request: TimeInterval? = nil
        var transfer: TimeInterval = 180
    }
    private nonisolated let timing: Timing
    private weak var device: VZVirtioSocketDevice?
    private(set) var isConnected = false
    private(set) var guestName = ""
    private(set) var guestCaps: [String] = []
    private(set) var guestIP: String?

    /// Whether touches should be injected guest-side via vphoned rather than the
    /// VZ USB touchscreen. Prefer the guest path whenever vphoned reports the
    /// capability: it is independent of host-private VZ touch event behavior and
    /// also covers guests whose USB touchscreen reports do not reach BackBoard.
    var useGuestTouchInjection: Bool {
        isConnected && guestCaps.contains("touch")
    }
    var touchSession: UInt64? {
        useGuestTouchInjection ? connectionAttemptToken : nil
    }

    /// Path to the signed vphoned binary. When set, enables auto-update.
    var guestBinaryURL: URL?

    /// Called when guest is ready (not updating). Receives guest capabilities.
    var onConnect: (([String]) -> Void)?

    /// Called when the guest disconnects (before reconnect attempt).
    var onDisconnect: (() -> Void)?

    private var guestBinaryData: Data?
    private var guestBinaryHash: String?
    private var nextRequestId: UInt64 = 0
    private var connectionAttemptToken: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?

    /// Serial queue for all outbound writes. Keeps blocking `write(2)` calls
    /// off the main thread and guarantees frame ordering across senders.
    private let writerQueue = DispatchQueue(label: "com.vphone.control.writer", qos: .userInitiated)

    /// Monotonic counter bumped on every disconnect. enqueueWrite snapshots
    /// it at enqueue time; the writer-queue closure refuses to run if the
    /// epoch has advanced, so backlog from a dead session cannot land on
    /// a recycled fd from the next connect attempt.
    private let writeEpochLock = NSLock()
    private nonisolated(unsafe) var _writeEpoch: UInt64 = 0

    private nonisolated func currentWriteEpoch() -> UInt64 {
        writeEpochLock.lock(); defer { writeEpochLock.unlock() }
        return _writeEpoch
    }

    private nonisolated func bumpWriteEpoch() {
        writeEpochLock.lock(); _writeEpoch &+= 1; writeEpochLock.unlock()
    }

    /// Bounds queue wait plus write time for every outbound frame. If the
    /// guest reader stops draining without closing the fd, `Darwin.write`
    /// would otherwise block forever — the response timeout never arms
    /// (it's gated on writer completion) and heartbeat is suppressed by
    /// `transfersInFlight`. The watchdog forces a disconnect after the
    /// transfer window so the awaiting API can fail and reconnect.
    /// Whichever of `fire()` and `cancel()` wins the lock drives the
    /// outcome; the loser becomes a no-op.
    private final class WriteWatchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let onTimeout: @Sendable () -> Void

        init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
            self.onTimeout = onTimeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                [weak self] in self?.fire()
            }
        }

        private func fire() {
            lock.lock(); let already = done; done = true; lock.unlock()
            if !already { onTimeout() }
        }

        func cancel() {
            lock.lock(); done = true; lock.unlock()
        }
    }

    /// Heartbeat state. Counts in-flight bulk transfers (uploadFile,
    /// clipboardSet(image), pushUpdate) so the heartbeat tick can skip while
    /// the writer is busy — large transfers must not be misread as dead links.
    private var heartbeatTimer: DispatchSourceTimer?
    private var transfersInFlight = 0

    public var variant: VPhoneVirtualMachine.Variant = .regular

    init(variant: VPhoneVirtualMachine.Variant, timing: Timing = Timing()) {
        self.timing = timing
        self.variant = variant
    }
    
    // MARK: - Pending Requests

    /// Removed atomically before invocation; continuation handlers can run on
    /// the actor, writer, timeout or caller-cancellation queue.
    private struct PendingRequest: @unchecked Sendable {
        let handler: (Result<([String: Any], Data?), any Error>) -> Void
    }

    private let pendingLock = NSLock()
    private nonisolated(unsafe) var pendingRequests: [String: PendingRequest] = [:]

    private nonisolated func addPending(
        id: String, handler: @escaping (Result<([String: Any], Data?), any Error>) -> Void
    ) {
        pendingLock.lock()
        pendingRequests[id] = PendingRequest(handler: handler)
        pendingLock.unlock()
    }

    private nonisolated func hasPending(id: String) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingRequests[id] != nil
    }

    private nonisolated func removePending(id: String) -> PendingRequest? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingRequests.removeValue(forKey: id)
    }

    private nonisolated func failAllPending(with error: ControlError = .notConnected) {
        pendingLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingLock.unlock()
        for (_, req) in pending {
            req.handler(.failure(error))
        }
    }

    enum ControlError: Error, CustomStringConvertible, Sendable {
        case notConnected
        case unsupportedCapability(String)
        case cancelled(String)
        case requestTimedOut(type: String, seconds: Int)
        case protocolError(String)
        case guestError(code: String?, message: String)

        var description: String {
            switch self {
            case .notConnected: "not connected to vphoned"
            case let .unsupportedCapability(capability):
                "guest does not support capability: \(capability)"
            case let .cancelled(reason): "request cancelled: \(reason); guest operation may continue"
            case let .requestTimedOut(type, seconds):
                "request timed out (\(type), \(seconds)s); guest operation may continue"
            case let .protocolError(msg): "protocol error: \(msg)"
            case let .guestError(_, message): message
            }
        }
    }

    nonisolated static func controlError(
        forGuestResponse response: [String: Any]
    ) -> ControlError {
        ControlError.guestError(
            code: response["code"] as? String,
            message: response["msg"] as? String ?? "unknown error")
    }

    private static func signCertURL() -> URL? {
        let signcert = VPhoneResources.resolve().signcert
        return FileManager.default.fileExists(atPath: signcert.path) ? signcert : nil
    }

    // MARK: - Guest Binary Hash

    private func loadGuestBinary() {
        guard let url = guestBinaryURL,
              let data = try? Data(contentsOf: url)
        else {
            guestBinaryData = nil
            guestBinaryHash = nil
            return
        }
        guestBinaryData = data
        guestBinaryHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print(
            "[control] vphoned binary: \(url.lastPathComponent) (\(data.count) bytes, \(guestBinaryHash!.prefix(12))...)"
        )
    }

    // MARK: - Connect

    func connect(device: VZVirtioSocketDevice) {
        close()
        self.device = device
        cancelReconnect()
        loadGuestBinary()
        attemptConnect()
    }

    /// The same connected-descriptor entry used by socketpair integration tests.
    /// The caller retains ownership of fd; this client owns a duplicate.
    func connect(fileDescriptor: Int32) throws {
        disconnect()
        cancelReconnect()
        device = nil
        connectionAttemptToken &+= 1
        channel = try VPhoneControlChannel(duplicating: fileDescriptor, readTimeout: timing.transfer)
        performHandshake(fd: channel!.fileDescriptor, attemptToken: connectionAttemptToken)
    }

    func close() {
        device = nil
        cancelReconnect()
        disconnect()
        connectionAttemptToken &+= 1
    }

    private func attemptConnect() {
        guard let device else { return }
        connectionAttemptToken += 1
        let attemptToken = connectionAttemptToken
        device.connect(toPort: Self.vsockPort) {
            [weak self] (result: Result<VZVirtioSocketConnection, any Error>) in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken) else { return }
                switch result {
                case let .success(conn):
                    do {
                        self.channel = try VPhoneControlChannel(duplicating: conn.fileDescriptor, readTimeout: self.timing.transfer)
                        self.connection = conn
                        self.performHandshake(fd: self.channel!.fileDescriptor, attemptToken: attemptToken)
                    } catch {
                        self.scheduleReconnect(for: attemptToken, reason: "cannot retain connection")
                    }
                case let .failure(error):
                    print("[control] connect failed: \(error)")
                    self.scheduleReconnect(for: attemptToken, reason: "connect failed")
                }
            }
        }
    }

    // MARK: - Handshake

    private func performHandshake(fd: Int32, attemptToken: UInt64) {
        var hello: [String: Any] = ["v": Self.protocolVersion, "t": "hello"]
        if let hash = guestBinaryHash {
            hello["bin_hash"] = hash
        }
        guard let helloFrame = Self.encodeFrame(hello) else {
            print("[control] handshake: failed to encode hello")
            disconnect(ifCurrentAttempt: attemptToken)
            return
        }
        enqueueWrite([helloFrame], fd: fd) { [weak self] ok in
            guard !ok else { return }
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                print("[control] handshake: failed to send hello")
                self.disconnect(ifCurrentAttempt: attemptToken)
            }
        }
        armHandshakeTimeout(fd: fd, attemptToken: attemptToken)

        guard let channel else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self, channel] in
            defer { withExtendedLifetime(channel) {} }
            guard let resp = Self.readMessage(fd: fd, timeout: channel.readTimeout) else {
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                    print("[control] handshake: no response")
                    self.disconnect(ifCurrentAttempt: attemptToken)
                }
                return
            }

            let version = resp["v"] as? Int ?? 0
            let type = resp["t"] as? String ?? ""
            let name = resp["name"] as? String ?? "unknown"
            let caps = resp["caps"] as? [String] ?? []
            let ip = resp["ip"] as? String
            let iosVersion = resp["ios"] as? String
            let needUpdate = resp["need_update"] as? Bool ?? false

            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                guard type == "hello", version == Self.protocolVersion else {
                    print(
                        "[control] handshake: version mismatch (guest v\(version), host v\(Self.protocolVersion))"
                    )
                    self.disconnect(ifCurrentAttempt: attemptToken)
                    return
                }
                self.guestName = name
                self.guestCaps = caps
                self.guestIP = ip
                self.isConnected = true
                let ipSuffix = ip.map { " (\($0))" } ?? ""
                let iosSuffix = iosVersion.map { " iOS \($0)" } ?? ""
                print("[control] connected to \(name) v\(version)\(ipSuffix)\(iosSuffix), caps: \(caps)")
                if self.useGuestTouchInjection {
                    print("[control] guest-side touch injection enabled (iOS \(iosVersion ?? "?"))")
                }

                if needUpdate && self.variant != .less {
                    self.pushUpdate(fd: fd)
                } else {
                    self.startReadLoop(fd: fd, attemptToken: attemptToken)
                    self.startHeartbeat()
                    self.onConnect?(caps)
                }
            }
        }
    }

    // MARK: - Auto-update Push

    private func pushUpdate(fd: Int32) {
        guard let data = guestBinaryData else {
            print("[control] update requested but no binary available")
            startReadLoop(fd: fd, attemptToken: connectionAttemptToken)
            return
        }

        print("[control] pushing update (\(data.count) bytes)...")
        nextRequestId += 1
        let header: [String: Any] = [
            "v": Self.protocolVersion, "t": "update", "id": String(nextRequestId, radix: 16),
            "size": data.count,
        ]
        guard let headerFrame = Self.encodeFrame(header) else {
            print("[control] update: failed to encode header")
            disconnect()
            return
        }
        // Header + binary payload as one indivisible writer task.
        beginTransfer()
        let attemptToken = connectionAttemptToken
        enqueueWrite([headerFrame, data], fd: fd) { [weak self] ok in
            Task { @MainActor in
                guard let self, self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                self.endTransfer()
                if !ok {
                    print("[control] update: failed to send")
                    self.disconnect()
                }
            }
        }
        print("[control] update queued, waiting for ack...")
        startReadLoop(fd: fd, attemptToken: connectionAttemptToken)
        startHeartbeat()
    }

    // MARK: - Send Commands

    func sendHIDPress(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: nil)
    }

    func sendHIDDown(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: true)
    }

    func sendHIDUp(page: UInt32, usage: UInt32) {
        sendHID(page: page, usage: usage, down: false)
    }

    private func sendHID(page: UInt32, usage: UInt32, down: Bool?) {
        nextRequestId += 1
        var msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "hid",
            "id": String(nextRequestId, radix: 16),
            "page": page,
            "usage": usage,
        ]
        if let down { msg["down"] = down }
        guard let fd = channel?.fileDescriptor, let frame = Self.encodeFrame(msg) else {
            print("[control] send failed (not connected)")
            return
        }
        enqueueWrite([frame], fd: fd) { ok in
            if !ok { print("[control] hid write failed") }
        }
        let suffix = down.map { $0 ? " down" : " up" } ?? ""
        print(
            "[control] hid page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16))\(suffix)"
        )
    }

    /// Inject a single-finger digitizer touch guest-side (bypasses VZ USB touch).
    /// phase: 0 = down, 1 = move, 3 = up. x/y are normalized 0..1, top-left origin.
    func sendTouch(phase: Int, x: Double, y: Double) {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "touch",
            "id": String(nextRequestId, radix: 16),
            "phase": phase,
            "x": x,
            "y": y,
        ]
        guard let fd = channel?.fileDescriptor, let frame = Self.encodeFrame(msg) else {
            print("[control] touch send failed (not connected)")
            return
        }
        enqueueWrite([frame], fd: fd) { ok in
            if !ok { print("[control] touch write failed") }
        }
    }

    // MARK: - Developer Mode

    struct DevModeStatus {
        let enabled: Bool
    }

    func sendDevModeStatus() async throws -> DevModeStatus {
        let (resp, _) = try await sendRequest(["t": "devmode", "action": "status"])
        let enabled = resp["enabled"] as? Bool ?? false
        return DevModeStatus(enabled: enabled)
    }

    func sendPing() async throws {
        _ = try await sendRequest(["t": "ping"])
    }

    func sendVersion() async throws -> String {
        let (resp, _) = try await sendRequest(["t": "version"])
        return resp["hash"] as? String ?? "unknown"
    }

    /// Cancel all currently pending request continuations.
    func cancelPendingRequests(reason: String = "cancelled by host") {
        failAllPending(with: .cancelled(reason))
    }

    // MARK: - Async Request-Response

    /// Send a request and await the response. Returns the response dict and optional raw data.
    func sendRequest(_ dict: [String: Any]) async throws -> ([String: Any], Data?) {
        try await performRequest(dict)
    }

    private func performRequest(_ dict: [String: Any], payload: Data? = nil) async throws -> ([String: Any], Data?) {
        try Task.checkCancellation()
        guard isConnected, let fd = channel?.fileDescriptor else { throw ControlError.notConnected }
        let attemptToken = connectionAttemptToken
        nextRequestId &+= 1
        let reqId = String(nextRequestId, radix: 16)
        var msg = dict
        msg["v"] = Self.protocolVersion
        msg["id"] = reqId
        let requestType = msg["t"] as? String ?? "unknown"
        let timeout = timing.request ?? Self.timeoutForRequest(type: requestType)
        guard let frame = Self.encodeFrame(msg) else {
            throw ControlError.protocolError("request JSON exceeds 4 MiB or cannot be encoded")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                addPending(id: reqId) { result in
                    nonisolated(unsafe) let r = result
                    continuation.resume(with: r)
                }
                // Covers cancellation between entering the operation and registration.
                if Task.isCancelled {
                    removePending(id: reqId)?.handler(.failure(ControlError.cancelled("caller task cancelled")))
                    return
                }
                if payload != nil { beginTransfer() }
                enqueueWrite(payload.map { [frame, $0] } ?? [frame], fd: fd,
                             requestID: reqId) { [weak self] ok in
                    guard let self else { return }
                    if ok {
                        self.armRequestTimeout(id: reqId, type: requestType, timeout: timeout)
                    } else if let pending = self.removePending(id: reqId) {
                        pending.handler(.failure(ControlError.notConnected))
                    }
                    Task { @MainActor in
                        guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                        if payload != nil { self.endTransfer() }
                        // A cancelled queued request was skipped without touching
                        // the stream. Actual I/O failures are handled by enqueueWrite.
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.removePending(id: reqId)?.handler(.failure(ControlError.cancelled("caller task cancelled")))
        }
    }

    // MARK: - File Operations

    func listFiles(path: String) async throws -> [[String: Any]] {
        let (resp, _) = try await sendRequest(["t": "file_list", "path": path])
        guard let entries = resp["entries"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing entries in response")
        }
        return entries
    }

    func downloadFile(path: String) async throws -> Data {
        let (_, data) = try await sendRequest(["t": "file_get", "path": path])
        guard let data else {
            throw ControlError.protocolError("no file data received")
        }
        return data
    }

    func uploadFile(path: String, data: Data, permissions: String = "644") async throws {
        _ = try await performRequest(["t": "file_put", "path": path, "size": data.count, "perm": permissions], payload: data)
    }

    func createDirectory(path: String) async throws {
        _ = try await sendRequest(["t": "file_mkdir", "path": path])
    }

    func deleteFile(path: String) async throws {
        _ = try await sendRequest(["t": "file_delete", "path": path])
    }

    func renameFile(from: String, to: String) async throws {
        _ = try await sendRequest(["t": "file_rename", "from": from, "to": to])
    }

    func installIPA(localURL: URL) async throws -> String {
        do {
            return try await installIPAWithBuiltInInstaller(localURL: localURL)
        } catch let ControlError.guestError(_, message)
            where message == "unknown type: ipa_install"
        {
            throw ControlError.guestError(
                code: nil,
                message: "Guest vphoned does not support ipa_install yet. Reconnect or reboot the guest so the updated daemon can take over."
            )
        }
    }

    private func installIPAWithBuiltInInstaller(localURL: URL) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: localURL)
        } catch {
            throw ControlError.protocolError("failed to read IPA: \(error)")
        }

        let remoteDir = "/var/mobile/Documents/vphone-installs"
        let remoteName = "\(UUID().uuidString)-\(localURL.lastPathComponent)"
        let remotePath = "\(remoteDir)/\(remoteName)"

        var cleanupPaths = [remotePath]
        defer {
            Task {
                for cleanupPath in cleanupPaths {
                    try? await deleteFile(path: cleanupPath)
                }
            }
        }

        try await createDirectory(path: remoteDir)
        try await uploadFile(path: remotePath, data: data)

        var request: [String: Any] = [
            "t": "ipa_install",
            "path": remotePath,
            "registration": "User",
        ]

        if let signCertURL = Self.signCertURL() {
            let signCertData = try Data(contentsOf: signCertURL)
            let certRemotePath = "\(remoteDir)/\(UUID().uuidString)-signcert.p12"
            cleanupPaths.append(certRemotePath)
            try await uploadFile(path: certRemotePath, data: signCertData)
            request["cert_path"] = certRemotePath
        }

        let (resp, _) = try await sendRequest(request)
        if let detail = resp["msg"] as? String, !detail.isEmpty {
            return detail
        }
        return "Installed \(localURL.lastPathComponent) through the built-in IPA installer."
    }

    // MARK: - Keychain Operations

    struct KeychainResult {
        let items: [[String: Any]]
        let diagnostics: [String]
    }

    func listKeychainItems(filterClass: String? = nil) async throws -> KeychainResult {
        var req: [String: Any] = ["t": "keychain_list"]
        if let filterClass { req["class"] = filterClass }
        let (resp, _) = try await sendRequest(req)
        guard let items = resp["items"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing items in keychain response")
        }
        let diag = resp["diag"] as? [String] ?? []
        return KeychainResult(items: items, diagnostics: diag)
    }

    func addKeychainItem(
        account: String = "vphone-test", service: String = "vphone", password: String = "testpass123"
    ) async throws -> Bool {
        let req: [String: Any] = [
            "t": "keychain_add", "account": account, "service": service, "password": password,
        ]
        let (resp, _) = try await sendRequest(req)
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "unknown error"
            throw ControlError.protocolError("keychain_add: \(msg)")
        }
        return true
    }

    // MARK: - Clipboard

    struct ClipboardContent {
        let text: String?
        let types: [String]
        let hasImage: Bool
        let changeCount: Int
        let imageData: Data?
    }

    func clipboardGet() async throws -> ClipboardContent {
        let (resp, data) = try await sendRequest(["t": "clipboard_get"])
        let text = resp["text"] as? String
        let types = resp["types"] as? [String] ?? []
        let hasImage = resp["has_image"] as? Bool ?? false
        let changeCount = resp["change_count"] as? Int ?? 0
        return ClipboardContent(
            text: text, types: types, hasImage: hasImage, changeCount: changeCount, imageData: data
        )
    }

    func clipboardSet(text: String) async throws {
        _ = try await sendRequest(["t": "clipboard_set", "text": text])
    }

    func clipboardSet(imageData: Data) async throws {
        _ = try await performRequest(["t": "clipboard_set", "type": "image", "size": imageData.count], payload: imageData)
    }

    // MARK: - App Management

    struct AppInfo {
        let bundleId: String
        let name: String
        let version: String
        let type: String
        let state: String
        let pid: Int
        let path: String
        let dataContainer: String
    }

    func appList(filter: String = "all") async throws -> [AppInfo] {
        let (resp, _) = try await sendRequest(["t": "app_list", "filter": filter])
        guard let apps = resp["apps"] as? [[String: Any]] else {
            throw ControlError.protocolError("missing apps in response")
        }
        return apps.map { app in
            AppInfo(
                bundleId: app["bundle_id"] as? String ?? "",
                name: app["name"] as? String ?? "",
                version: app["version"] as? String ?? "",
                type: app["type"] as? String ?? "",
                state: app["state"] as? String ?? "",
                pid: app["pid"] as? Int ?? 0,
                path: app["path"] as? String ?? "",
                dataContainer: app["data_container"] as? String ?? ""
            )
        }
    }

    func appLaunch(bundleId: String, url: String? = nil) async throws -> Int {
        var req: [String: Any] = ["t": "app_launch", "bundle_id": bundleId]
        if let url { req["url"] = url }
        let (resp, _) = try await sendRequest(req)
        // The guest fails closed (ok=false + msg) when the launch did not
        // materialize; propagate that instead of reporting a phantom success.
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError(
                code: nil,
                message: resp["msg"] as? String ?? "failed to launch \(bundleId)")
        }
        return resp["pid"] as? Int ?? 0
    }

    func appTerminate(bundleId: String) async throws {
        let (resp, _) = try await sendRequest(["t": "app_terminate", "bundle_id": bundleId])
        // The guest verifies the process is gone and returns ok=false if it is
        // still running; don't swallow that into an unconditional success.
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError(
                code: nil,
                message: resp["msg"] as? String ?? "failed to terminate \(bundleId)")
        }
    }

    func appForeground() async throws -> (bundleId: String, name: String, pid: Int, source: String) {
        let (resp, _) = try await sendRequest(["t": "app_foreground"])
        return (
            bundleId: resp["bundle_id"] as? String ?? "",
            name: resp["name"] as? String ?? "",
            pid: resp["pid"] as? Int ?? 0,
            // Older guests omit `source`; absent means "trust bundle_id as before".
            source: resp["source"] as? String ?? ""
        )
    }

    // MARK: - URL

    func openURL(_ url: String) async throws {
        let (resp, _) = try await sendRequest(["t": "open_url", "url": url])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            let msg = resp["msg"] as? String ?? "failed to open URL"
            throw ControlError.guestError(code: nil, message: msg)
        }
    }

    // MARK: - Shell

    struct ShellResult {
        let stdout: String
        let stderr: String
        let exitCode: Int
        let timedOut: Bool
        let truncated: Bool
    }

    /// Run a command on the guest via `/bin/sh -c`. Requires the `shell`
    /// capability (guest must have `/bin/sh`). `timeoutMs`, when set, bounds
    /// the command on the guest side; it is clamped there to 120s.
    func runShell(command: String, cwd: String? = nil, timeoutMs: Int? = nil) async throws
        -> ShellResult
    {
        guard guestCaps.contains("shell") else {
            throw ControlError.unsupportedCapability("shell")
        }
        var req: [String: Any] = ["t": "shell", "cmd": command]
        if let cwd { req["cwd"] = cwd }
        if let timeoutMs { req["timeout_ms"] = timeoutMs }
        let (resp, _) = try await sendRequest(req)
        return ShellResult(
            stdout: resp["out"] as? String ?? "",
            stderr: resp["err"] as? String ?? "",
            exitCode: resp["code"] as? Int ?? -1,
            timedOut: resp["timed_out"] as? Bool ?? false,
            truncated: resp["truncated"] as? Bool ?? false
        )
    }

    // MARK: - Power off

    /// Whether the guest OS can be asked to power itself off over this
    /// connection (needs vphoned's `shell`, i.e. a `/bin/sh` in the guest).
    var canHaltGuest: Bool { isConnected && guestCaps.contains("shell") }

    /// Ask the guest OS to power itself off.
    ///
    /// Returns false only when the guest reports it has no power-off binary.
    /// A transport error counts as delivered: the vsock connection normally
    /// dies while the guest is powering off, so the request may well have run.
    func haltGuest() async -> Bool {
        guard canHaltGuest else { return false }
        do {
            let result = try await runShell(
                command: VPhoneShutdownPolicy.guestHaltCommand, timeoutMs: 5000)
            if result.exitCode == VPhoneShutdownPolicy.guestHaltUnsupportedExitCode {
                print("[vphone] guest has no power-off command")
                return false
            }
            return true
        } catch {
            print("[vphone] guest power-off request ended with: \(error)")
            return true
        }
    }

    // MARK: - Settings

    func settingsGet(domain: String, key: String? = nil) async throws -> Any? {
        var req: [String: Any] = ["t": "settings_get", "domain": domain]
        if let key { req["key"] = key }
        let (resp, _) = try await sendRequest(req)
        return resp["value"]
    }

    func settingsSet(domain: String, key: String, value: Any, type: String? = nil) async throws {
        var req: [String: Any] = ["t": "settings_set", "domain": domain, "key": key, "value": value]
        if let type { req["type"] = type }
        _ = try await sendRequest(req)
    }

    func lowPowerMode(enabled: Bool) async throws {
        let (resp, _) = try await sendRequest(["t": "low_power_mode", "enabled": enabled])
        let ok = resp["ok"] as? Bool ?? false
        if !ok {
            throw ControlError.guestError(
                code: nil,
                message: "low_power_mode: failed to set state on guest")
        }
    }

    // MARK: - Accessibility

    func accessibilityTree(depth: Int = -1) async throws -> [String: Any] {
        guard guestCaps.contains("accessibility_tree") else {
            throw ControlError.unsupportedCapability("accessibility_tree")
        }
        let (resp, _) = try await sendRequest(["t": "accessibility_tree", "depth": depth])
        return resp
    }

    // MARK: - Location

    func sendLocation(
        latitude: Double, longitude: Double, altitude: Double,
        horizontalAccuracy: Double, verticalAccuracy: Double,
        speed: Double, course: Double
    ) {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "location",
            "id": String(nextRequestId, radix: 16),
            "lat": latitude,
            "lon": longitude,
            "alt": altitude,
            "hacc": horizontalAccuracy,
            "vacc": verticalAccuracy,
            "speed": speed,
            "course": course,
            "ts": Date().timeIntervalSince1970,
        ]
        guard let fd = channel?.fileDescriptor, let frame = Self.encodeFrame(msg) else {
            print("[control] sendLocation failed (not connected)")
            return
        }
        enqueueWrite([frame], fd: fd) { ok in
            if !ok { print("[control] location write failed") }
        }
        print("[control] location lat=\(latitude) lon=\(longitude)")
    }

    func sendLocationStop() {
        nextRequestId += 1
        let msg: [String: Any] = [
            "v": Self.protocolVersion,
            "t": "location_stop",
            "id": String(nextRequestId, radix: 16),
        ]
        guard let fd = channel?.fileDescriptor, let frame = Self.encodeFrame(msg) else { return }
        enqueueWrite([frame], fd: fd)
    }

    // MARK: - Disconnect & Reconnect

    private func disconnect(ifCurrentAttempt expectedAttemptToken: UInt64? = nil) {
        if let expectedAttemptToken, !isCurrentAttempt(expectedAttemptToken) {
            return
        }

        let reconnectAttemptToken = connectionAttemptToken
        let wasConnected = isConnected
        let hadConnection = channel != nil
        // Bump before clearing connection so writer-queue tasks observe the
        // new epoch even if they race against the rest of teardown.
        bumpWriteEpoch()
        channel?.shutdown()
        channel = nil
        connection = nil
        isConnected = false
        guestName = ""
        guestCaps = []
        guestIP = nil
        stopHeartbeat()
        transfersInFlight = 0

        // Fail all pending requests
        failAllPending()

        if wasConnected {
            onDisconnect?()
        }

        if hadConnection, device != nil {
            scheduleReconnect(for: reconnectAttemptToken, reason: "connection lost")
        }
    }

    // MARK: - Background Read Loop

    private func startReadLoop(fd: Int32, attemptToken: UInt64) {
        guard let channel else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, channel] in
            defer { withExtendedLifetime(channel) {} }
            while let msg = Self.readMessage(fd: fd, timeout: channel.readTimeout) {
                guard let self else { break }
                let type = msg["t"] as? String ?? ""
                // Consume payloads even for cancelled, duplicate or unknown IDs.
                // Keep the request registered until all bytes arrive, so its
                // timeout/cancellation can still resume the caller during I/O.
                var data: Data?
                let payloadKey: String? = type == "file_data" ? "size"
                    : (type == "clipboard_get" && msg["has_image"] as? Bool == true ? "image_size" : nil)
                if let payloadKey {
                    guard let number = msg[payloadKey] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue >= 0, number.doubleValue <= 64 * 1024 * 1024,
                          number.doubleValue.rounded(.towardZero) == number.doubleValue else { break }
                    let size = number.intValue
                    var payload = Data(count: size)
                    let complete = payload.withUnsafeMutableBytes { bytes in
                        size == 0 || Self.readFully(fd: fd, buf: bytes.baseAddress!, count: size, deadline: Self.deadline(after: channel.readTimeout))
                    }
                    guard complete else { break }
                    data = payload
                }
                nonisolated(unsafe) let response = msg
                let payload = data
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                    guard let id = response["id"] as? String,
                          let pending = self.removePending(id: id) else {
                        switch type {
                        case "ok":
                            if let detail = response["msg"] as? String, !detail.isEmpty { print("[vphoned] ok: \(detail)") }
                        case "pong": print("[vphoned] pong")
                        case "version": print("[vphoned] build: \(response["hash"] as? String ?? "unknown")")
                        case "err": print("[vphoned] error: \(response["msg"] as? String ?? "unknown")")
                        default: break
                        }
                        return
                    }
                    if type == "err" {
                        pending.handler(.failure(Self.controlError(forGuestResponse: response)))
                    } else {
                        pending.handler(.success((response, payload)))
                    }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                print("[control] read loop ended")
                self.disconnect(ifCurrentAttempt: attemptToken)
            }
        }
    }

    // MARK: - Reconnect Coordination

    private func isCurrentAttempt(_ attemptToken: UInt64, fd: Int32? = nil) -> Bool {
        guard connectionAttemptToken == attemptToken else { return false }
        guard let fd else { return true }
        return channel?.fileDescriptor == fd
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleReconnect(for attemptToken: UInt64, reason: String) {
        guard isCurrentAttempt(attemptToken) else { return }
        guard device != nil else { return }

        cancelReconnect()
        let delay = Self.reconnectDelay
        print("[control] \(reason); reconnecting in \(Int(delay.rounded()))s...")

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentAttempt(attemptToken) else { return }
                self.reconnectWorkItem = nil
                self.loadGuestBinary()
                self.attemptConnect()
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func armHandshakeTimeout(fd: Int32, attemptToken: UInt64) {
        let timeout = timing.handshake
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            guard isCurrentAttempt(attemptToken, fd: fd) else { return }
            guard !isConnected else { return }
            print("[control] handshake timed out after \(Int(timeout.rounded()))s")
            Self.shutdownSocket(fd: fd)
            disconnect(ifCurrentAttempt: attemptToken)
        }
    }

    // MARK: - Request Timeout

    private static func timeoutForRequest(type: String) -> TimeInterval {
        switch type {
        case "file_get", "file_put", "ipa_install":
            transferRequestTimeout
        case "shell":
            transferRequestTimeout
        case "devmode", "file_list", "file_delete", "file_rename", "file_mkdir", "keychain_list",
             "app_list", "app_launch", "open_url", "accessibility_tree":
            slowRequestTimeout
        default:
            defaultRequestTimeout
        }
    }

    private nonisolated func armRequestTimeout(id: String, type: String, timeout: TimeInterval) {
        guard timeout > 0 else { return }
        let timeoutSeconds = max(Int(timeout.rounded()), 1)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            guard let pending = removePending(id: id) else { return }
            DispatchQueue.main.async {
                pending.handler(.failure(ControlError.requestTimedOut(type: type, seconds: timeoutSeconds)))
            }
        }
    }

    // MARK: - Heartbeat

    /// Start the idle-aware heartbeat. Fires every `heartbeatInterval` on the
    /// main actor; skips ticks while bulk transfers are in flight to avoid
    /// false-positive dead-link detection during long uploads.
    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.heartbeatInterval,
            repeating: Self.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.heartbeatTick() }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func heartbeatTick() {
        guard isConnected else { return }
        // Skip while a bulk transfer is in flight — the writer queue may be
        // saturated and a ping would queue up behind it.
        guard transfersInFlight == 0 else { return }
        let attemptToken = connectionAttemptToken
        Task { [weak self] in
            do {
                try await self?.sendPing()
            } catch {
                guard let self else { return }
                guard self.isConnected, self.isCurrentAttempt(attemptToken) else { return }
                print("[control] heartbeat failed: \(error); disconnecting")
                self.disconnect()
            }
        }
    }

    private func beginTransfer() { transfersInFlight += 1 }
    private func endTransfer() {
        transfersInFlight = max(0, transfersInFlight - 1)
    }

    // MARK: - Framing: Length-Prefixed JSON

    /// Encode a dictionary as a length-prefixed JSON frame:
    /// `[uint32 big-endian length][UTF-8 JSON]`.
    private static func encodeFrame(_ dict: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: dict),
              !json.isEmpty, json.count <= 4 * 1024 * 1024 else { return nil }
        var header = UInt32(json.count).bigEndian
        var frame = Data(capacity: 4 + json.count)
        withUnsafeBytes(of: &header) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame
    }

    /// Enqueue an atomic write of one or more byte buffers onto the serial
    /// writer queue. The chunks are written in order as a single indivisible
    /// task, so a frame (and any trailing binary payload) can never be
    /// interleaved with another sender's bytes. All blocking `write(2)` calls
    /// run off the main thread, each via `writeFully` (no partial-write gaps).
    /// `completion` runs on the writer queue with the overall success flag; a
    /// `shutdown(2)` from `disconnect()` unblocks any in-flight write and
    /// surfaces here as `false`.
    private func enqueueWrite(
        _ chunks: [Data], fd: Int32, requestID: String? = nil,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard let channel, channel.fileDescriptor == fd else { completion?(false); return }
        let expectedEpoch = currentWriteEpoch()
        let attemptToken = connectionAttemptToken
        let watchdog = WriteWatchdog(timeout: timing.transfer) { [weak self, channel] in
            channel.shutdown()
            Task { @MainActor in
                guard let self, self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                self.disconnect(ifCurrentAttempt: attemptToken)
            }
        }
        writerQueue.async { [weak self, channel] in
            defer { watchdog.cancel(); withExtendedLifetime(channel) {} }
            // Drop writes whose connection has been torn down. Even if the
            // raw fd number is now valid again (reused by a new connect),
            // the bytes belong to a dead session and would poison the new
            // handshake/stream.
            guard let self, self.currentWriteEpoch() == expectedEpoch else {
                completion?(false)
                return
            }
            guard requestID.map({ self.hasPending(id: $0) }) != false else { completion?(false); return }
            var ok = true
            for chunk in chunks where !chunk.isEmpty {
                ok = chunk.withUnsafeBytes { buf in
                    Self.writeFully(fd: fd, buf: buf.baseAddress!, count: chunk.count)
                }
                if !ok { break }
            }
            completion?(ok)
            if !ok {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentAttempt(attemptToken, fd: fd) else { return }
                    self.disconnect(ifCurrentAttempt: attemptToken)
                }
            }
        }
    }

    private nonisolated static func readMessage(fd: Int32, timeout: TimeInterval) -> [String: Any]? {
        let deadline = deadline(after: timeout)
        var header: UInt32 = 0
        let hRead = withUnsafeMutableBytes(of: &header) { buf in
            readFully(fd: fd, buf: buf.baseAddress!, count: 4, deadline: deadline)
        }
        guard hRead else { return nil }

        let length = Int(UInt32(bigEndian: header))
        guard length > 0, length <= 4 * 1024 * 1024 else { return nil }

        let payload = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { payload.deallocate() }
        guard readFully(fd: fd, buf: payload, count: length, deadline: deadline) else { return nil }

        let data = Data(bytes: payload, count: length)
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = message["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              message["t"] is String else { return nil }
        return message
    }

    private nonisolated static func deadline(after seconds: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
    }

    private nonisolated static func readFully(fd: Int32, buf: UnsafeMutableRawPointer, count: Int,
                                             deadline: UInt64) -> Bool {
        var offset = 0
        while offset < count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(UInt64(Int32.max), max(1, (deadline - now) / 1_000_000)))
            let ready = poll(&event, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return false }
            let n = Darwin.recv(fd, buf + offset, count - offset, MSG_DONTWAIT)
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    private nonisolated static func writeFully(fd: Int32, buf: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, buf + offset, count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private nonisolated static func shutdownSocket(fd: Int32) {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
}
