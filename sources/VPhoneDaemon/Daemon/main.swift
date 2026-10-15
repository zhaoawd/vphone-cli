import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import VphonedNative

let daemonMode = GuestDaemonMode(environment: ProcessInfo.processInfo.environment)
let apiOnly = daemonMode.apiOnly
let cameraEnabled = daemonMode.cameraEnabled
let mode = vp_native_process_mode()
if mode != 1 {
    guard mode == 0 else { exit(64) }
    if !apiOnly { vp_native_bootstrap_cached_binary() }
    exit(vp_native_run_proxy())
}

guard vp_native_watch_proxy() == 0 else { exit(1) }
if !apiOnly {
    if cameraEnabled { vp_vcam_start() }
    GuestIrisinInstaller.refreshBootstrapOnStartup()
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let filePool = NIOThreadPool(numberOfThreads: 2)
filePool.start()
let fileIO = NonBlockingFileIO(threadPool: filePool)
let hub = APIEventHub()
let eventPublisher = GuestEventPublisher(hub: hub)

@Sendable func initializeAPIChannel(_ channel: Channel) -> EventLoopFuture<Void> {
    let proxyAdmission = GuestProxyAdmission()
    let http = GuestHyperTextHandler(hub: hub, fileIO: fileIO, proxyAdmission: proxyAdmission)
    let upgrader = NIOWebSocketServerUpgrader(
        maxFrameSize: 1 << 20,
        shouldUpgrade: { channel, request in
            // Browsers apply no CORS to WebSockets; refuse any handshake
            // that carries Origin or a non-loopback Host. The refused
            // request then reaches GuestHyperTextHandler, which replies 403.
            let allowed = GuestHyperTextHandler.isLocalClient(request.headers) &&
                (request.uri == "/v1/events" || GuestPortForwardHandler.port(from: request.uri) != nil)
            guard allowed, proxyAdmission.consumeRequest() else { return channel.eventLoop.makeSucceededFuture(nil) }
            // A client that gave the host proxy its token as a WebSocket
            // subprotocol expects the server to select that protocol.
            var headers = HTTPHeaders()
            if let offered = request.headers[canonicalForm: "Sec-WebSocket-Protocol"]
                .first(where: { $0.hasPrefix("vphone-token.") })
            {
                headers.add(name: "Sec-WebSocket-Protocol", value: String(offered))
            }
            return channel.eventLoop.makeSucceededFuture(headers)
        },
        upgradePipelineHandler: { channel, request in
            // Add the post-upgrade handlers synchronously on the channel's
            // event loop (removeHandler's future completes there). Building
            // them through syncOperations keeps them off any concurrency
            // boundary, so NIOWebSocketFrameAggregator's unavailable Sendable
            // conformance is never required. The pipeline is unchanged.
            channel.pipeline.removeHandler(http).flatMapThrowing {
                let sync = channel.pipeline.syncOperations
                if let port = GuestPortForwardHandler.port(from: request.uri) {
                    try sync.addHandlers([
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 32,
                            maxAccumulatedFrameSize: 1 << 20,
                        ),
                        GuestPortForwardHandler(port: port),
                    ])
                } else {
                    try sync.addHandlers([
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1,
                            maxAccumulatedFrameCount: 32,
                            maxAccumulatedFrameSize: 1 << 20,
                        ),
                        GuestWebSocketHandler(hub: hub, externalProxy: proxyAdmission.external),
                    ])
                }
            }
        },
    )
    return channel.pipeline.configureHTTPServerPipeline(
        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
    ).flatMapThrowing {
        let sync = channel.pipeline.syncOperations
        let upgrade = try sync.handler(type: HTTPServerUpgradeHandler.self)
        try sync.addHandler(GuestProxyAdmissionHandler(admission: proxyAdmission, health: GuestAPI.health), position: .before(upgrade))
        try sync.addHandler(http)
    }
}

// NIO owns independent pipes. The native relay keeps AF_VSOCK blocking and
// applies bounded backpressure without changing NIO's event-loop sockets.
func attachAPIChannel(input: Int32, output: Int32) -> Int32 {
    do {
        _ = try makeGuestPipeChannel(input: input, output: output, group: group) {
            initializeAPIChannel($0)
        }
            .wait()
        return 0
    } catch {
        NSLog("vphoned: API pipe initialization failed: %@", String(describing: error))
        return -1
    }
}

let listener = vp_native_api_open()
guard listener >= 0 else {
    NSLog("vphoned: HTTP/WebSocket VSOCK listen failed: %d", errno)
    exit(1)
}
vp_native_confirm_cached_binary()
NSLog("vphoned: HTTP/WebSocket API listening on vsock 1339")
_ = vp_native_api_serve(listener) { input, output in
    attachAPIChannel(input: input, output: output)
}
close(listener)
NSLog("vphoned: HTTP/WebSocket accept stopped: %d", errno)

try? group.syncShutdownGracefully()
try? filePool.syncShutdownGracefully()
_ = eventPublisher
