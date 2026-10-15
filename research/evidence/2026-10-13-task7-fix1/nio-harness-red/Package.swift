// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "Admission", platforms: [.macOS(.v15)], dependencies: [.package(path: "/private/tmp/vphone-task7-daemon-packages/checkouts/swift-nio")], targets: [.target(name: "Admission", dependencies: [.product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOWebSocket", package: "swift-nio")]), .testTarget(name: "AdmissionTests", dependencies: ["Admission", .product(name: "NIOEmbedded", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOWebSocket", package: "swift-nio")])])
