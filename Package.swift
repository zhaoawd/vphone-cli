// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git",
                 revision: "82687c75e530917b7fbeb15cd5f9369524637155"),
        .package(path: "vendor/swift-argument-parser"),
        .package(path: "vendor/Dynamic"),
        .package(path: "vendor/libcapstone-spm"),
        .package(path: "vendor/libimg4-spm"),
        .package(path: "vendor/MachOKit"),
    ],
    targets: [
        .target(
            name: "VPhoneArchiveKit",
            dependencies: [.product(name: "ArchiveKit", package: "libarchive.xcframework")],
            path: "sources/VPhoneArchiveKit"
        ),
        .target(
            name: "VPhoneSign",
            path: "sources/VPhoneSign",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "FirmwarePatcher",
            dependencies: [
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "Img4tool", package: "libimg4-spm"),
                .product(name: "MachOKit", package: "MachOKit"),
                "VPhoneCore",
            ],
            path: "sources/FirmwarePatcher"
        ),
        .target(
            name: "VPhoneCore",
            dependencies: ["VPhoneArchiveKit"],
            path: "sources/VPhoneCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
                "FirmwarePatcher",
                "VPhoneCore",
                "VPhoneSign",
                "VPhoneArchiveKit",
            ],
            path: "sources/vphone-cli",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "FirmwarePatcherTests",
            dependencies: ["FirmwarePatcher", .product(name: "Img4tool", package: "libimg4-spm")],
            path: "tests/FirmwarePatcherTests"
        ),
        .testTarget(
            name: "FirmwareIntegrationTests",
            dependencies: ["FirmwarePatcher"],
            path: "tests/FirmwareIntegrationTests"
        ),
        .testTarget(
            name: "VPhoneCLITests",
            dependencies: ["vphone-cli"],
            path: "tests/VPhoneCLITests"
        ),
        .testTarget(
            name: "VPhoneArchiveKitTests",
            dependencies: ["VPhoneArchiveKit", "VPhoneCore",
                           .product(name: "ArchiveKit", package: "libarchive.xcframework")],
            path: "tests/VPhoneArchiveKitTests"
        ),
        .testTarget(
            name: "VPhoneSignTests",
            dependencies: ["VPhoneSign"],
            path: "tests/VPhoneSignTests"
        ),
        .testTarget(
            name: "VPhoneCoreTests",
            dependencies: ["VPhoneCore"],
            path: "tests/VPhoneCoreTests"
        ),
    ]
)
