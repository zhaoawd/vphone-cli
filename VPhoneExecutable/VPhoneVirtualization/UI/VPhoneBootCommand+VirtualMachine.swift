import Foundation
import VPhoneCoreKit

/// The half of VPhoneBootCommand that needs the Virtualization framework. The
/// options themselves live in VPhoneCoreKit so vphone-cli can parse and forward
/// them without linking any of this.
extension VPhoneBootCommand {
    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        // config.plist is rewritten on first boot; a symbolic link here would
        // be read from and written back through to a file outside the bundle.
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: config) else {
            throw VPhoneManifestError.loadFailed(path: config.path)
        }
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        // A foldable guest boots config.plist's screen: the cover for the
        // fold, or the display `vm config --display` chose.
        var screen = (
            width: manifest.screenConfig.width,
            height: manifest.screenConfig.height,
            ppi: manifest.screenConfig.pixelsPerInch,
        )
        // Experimental: VPHONE_SCREEN=<width>x<height>@<ppi> boots this run at
        // another panel size without changing config.plist.
        if let spec = ProcessInfo.processInfo.environment["VPHONE_SCREEN"] {
            let parts = spec.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
            if parts.count == 3, parts.allSatisfy({ $0 > 0 }) {
                screen = (parts[0], parts[1], parts[2])
                print("[vphone] Screen override from VPHONE_SCREEN: \(spec) (experimental)")
            } else {
                print("[vphone] Ignoring VPHONE_SCREEN=\(spec): expected <width>x<height>@<ppi>")
            }
        }

        return try VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages.map { try manifest.resolve(path: $0.avpBooter, in: vmDir) },
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages.map { try manifest.resolve(path: $0.avpSEPBooter, in: vmDir) },
            screenWidth: screen.width,
            screenHeight: screen.height,
            screenPPI: screen.ppi,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
            isPadGuest: manifest.guestDevice.isPad,
            isTVGuest: manifest.guestDevice.family == .appleTV,
            isHomePodGuest: manifest.guestDevice.family == .homePod,
            isWatchGuest: manifest.guestDevice.family == .watch,
            isFoldableGuest: manifest.guestDevice == .iPhone19_4
        )
    }
}
