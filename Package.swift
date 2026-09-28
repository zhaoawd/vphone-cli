// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "VPhoneAPIKit", targets: ["VPhoneAPIKit"]),
        .executable(name: "vphone-cli", targets: ["VPhoneCommandEntry"]),
        .executable(name: "vphone-vm", targets: ["VPhoneVMEntry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/AppleMobileDeviceLibrary.git",
                 revision: "553a0bf1b55812b1a08c727b1a3084e88871343b"),
        .package(url: "https://github.com/Lakr233/openssl-spm.git",
                 revision: "9f3b525d960fe71e534482310e96cd9c4f2faa17"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git",
                 revision: "82687c75e530917b7fbeb15cd5f9369524637155"),
        .package(path: "vendor/swift-argument-parser"),
        .package(path: "vendor/Dynamic"),
        .package(path: "vendor/libcapstone-spm"),
        .package(path: "vendor/libimg4-spm"),
        .package(path: "vendor/MachOKit"),
    ],
    targets: [
        .target(name: "VPhoneAPIKit", path: "sources/VPhoneAPIKit"),
        .testTarget(name: "VPhoneAPIKitTests", dependencies: ["VPhoneAPIKit"],
                    path: "tests/VPhoneAPIKitTests"),
        .target(name: "VPhoneDaemonWire", path: "sources/VPhoneDaemon/Daemon/Wire"),
        .testTarget(name: "VPhoneDaemonWireTests", dependencies: ["VPhoneDaemonWire"],
                    path: "tests/VPhoneDaemonWireTests"),
        .target(
            name: "MobileRecoveryCore",
            dependencies: [.product(name: "AppleMobileDeviceLibrary", package: "AppleMobileDeviceLibrary")],
            path: "sources/MobileRecoveryCore", exclude: ["COPYING"],
            publicHeadersPath: "Include",
            cSettings: [.define("HAVE_CONFIG_H", to: "1"), .define("IRECV_STATIC", to: "1"), .headerSearchPath(".")],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "MobileRestoreCore",
            dependencies: ["MobileRecoveryCore", .product(name: "AppleMobileDeviceLibrary", package: "AppleMobileDeviceLibrary")],
            path: "sources/MobileRestoreCore", exclude: ["COPYING"],
            publicHeadersPath: "Include",
            cSettings: [.define("HAVE_CONFIG_H", to: "1"), .define("IRECV_STATIC", to: "1"),
                        .define("IDEVICERESTORE_NOMAIN", to: "1"),
                        .headerSearchPath("."), .headerSearchPath("Core"), .headerSearchPath("Transfer"),
                        .headerSearchPath("Firmware"), .headerSearchPath("Firmware/Images"),
                        .headerSearchPath("Firmware/Containers"), .headerSearchPath("Recovery"), .headerSearchPath("Bridge")],
            linkerSettings: [.linkedLibrary("curl"), .linkedLibrary("z")]
        ),
        .target(name: "VPhoneRestore", dependencies: ["MobileRecoveryCore", "MobileRestoreCore"],
                path: "sources/VPhoneRestore", linkerSettings: [.linkedLibrary("z")]),
        .testTarget(name: "VPhoneRestoreTests", dependencies: ["VPhoneRestore", "MobileRestoreCore"],
                    path: "tests/VPhoneRestoreTests"),
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
        .executableTarget(name: "VPhoneCommandEntry", dependencies: ["vphone-cli"], path: "sources/VPhoneCommandEntry"),
        .executableTarget(name: "VPhoneVMEntry", dependencies: ["vphone-cli"], path: "sources/VPhoneVMEntry"),
        .target(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
                "FirmwarePatcher",
                "VPhoneCore",
                "VPhoneAPIKit",
                "VPhoneSign",
                "VPhoneRestore",
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
