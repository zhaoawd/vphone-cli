import Foundation
import VPhoneCore

// The executor depends on operations rather than VM views or socket descriptors.
@MainActor
protocol VPhoneHostGuest: AnyObject {
    var isConnected: Bool { get }
    var guestCaps: [String] { get }
    func sendHIDPress(page: UInt32, usage: UInt32)
    func clipboardSet(text: String) async throws
    func runShell(command: String, cwd: String?, timeoutMs: Int?) async throws -> VPhoneControl.ShellResult
    func downloadFile(path: String) async throws -> Data
    func uploadFile(path: String, data: Data, permissions: String) async throws
    func appLaunch(bundleId: String, url: String?) async throws -> Int
    func appTerminate(bundleId: String) async throws
    func appList(filter: String) async throws -> [VPhoneControl.AppInfo]
    func appForeground() async throws -> (bundleId: String, name: String, pid: Int, source: String)
    func openURL(_ url: String) async throws
    func sendRequest(_ dict: [String: Any]) async throws -> ([String: Any], Data?)
}

extension VPhoneControl: VPhoneHostGuest {}

@MainActor
protocol VPhoneHostScreen: AnyObject {
    var isAvailable: Bool { get }
    func saveScreenshot(to url: URL) async throws -> URL
    func captureCompactScreenshot(color: Bool) async -> String?
    func tap(x: Double, y: Double)
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int)
}

@MainActor
protocol VPhoneHostCamera: AnyObject {
    var isConnected: Bool { get }
    func present(imagePath: String, generation: String, role: String, fps: Double) -> Bool
    func hostStatus(generation: String) -> [String: Any]
    func stop(generation: String) -> Bool
}

extension VPhoneCameraServer: VPhoneHostCamera {}

@MainActor
protocol VPhoneHostLocation: AnyObject {
    var systemLocationController: VPhoneSystemLocationController { get }
    func externalControlCheck() -> @MainActor () throws -> Void
}

extension VPhoneLocationProvider: VPhoneHostLocation {
    func externalControlCheck() -> @MainActor () throws -> Void {
        let ownership = beginExternalControl()
        return { try self.requireExternalControl(ownership) }
    }
}
