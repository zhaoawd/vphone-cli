import AppKit
import Foundation
import VPhoneCoreKit

// Only transport, the host location helper, and alert presentation are faked.
// Compile the real menu actions, provider, adapter, controller and guest owner.
@MainActor
final class VPhoneGuestControl {
    enum ControlError: Error { case locationServicesOff }
    struct GuestRPCFailure: Error, @unchecked Sendable {
        let body: [String: Any]
        let message: String
    }
    var isConnected = true
    var guestCapabilities = ["location", "location_owned"]
    var syncsHostLocation = false
    var onLocationFailure: ((Error) -> Void)?
    let owned = GuestOwnedLocation()
    var lastLatitude: Double?
    var events: [String] = []
    var failClear = false
    var drains = 0

    func rpcAfterQueuedInput(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        events.append(method)
        do {
            switch method {
            case "location.source.begin":
                return try owned.begin(params["generation"] as! String) { self.clear() }
            case "location.source.deliver":
                return try owned.deliver(params["generation"] as! String,
                    sequence: params["delivery_sequence"] as! Int, payload: params) { self.apply(params) }
            case "location.source.clear":
                if failClear {
                    throw GuestRPCFailure(body: ["code": "location_generation_conflict"], message: "clear refused")
                }
                return try owned.stop(params["generation"] as! String) { self.clear() }
            case "location.clear": return try owned.unowned { self.clear() }
            case "location.set": return try owned.unowned { self.apply(params) }
            default: fatalError("unexpected test RPC: \(method)")
            }
        } catch let failure as GuestOwnedLocation.Failure {
            throw GuestRPCFailure(body: ["code": failure.code], message: failure.description)
        }
    }

    private func apply(_ params: [String: Any]) -> [String: Any] {
        lastLatitude = params["latitude"] as? Double
        return ["simulating": true]
    }
    private func clear() -> [String: Any] { lastLatitude = nil; return ["simulating": false] }
    func drainLocationUpdates() async { drains += 1 }
    func sendLocation(latitude: Double, longitude: Double, altitude: Double,
                      horizontalAccuracy: Double, verticalAccuracy: Double, speed: Double, course: Double) {
        do {
            _ = try owned.unowned { self.apply(["latitude": latitude, "longitude": longitude]) }
        } catch { onLocationFailure?(error) }
    }
    func sendLocationStop() { _ = try? owned.unowned { self.clear() } }
}

@MainActor
final class VPhoneMenuController: NSObject {
    let control: VPhoneGuestControl
    var locationProvider: VPhoneLocationProvider?
    var onHostLocationSyncChange: ((Bool) throws -> Void)?
    var locationMenuItem: NSMenuItem?
    var locationPresetMenuItem: NSMenuItem?
    var locationReplayStartItem: NSMenuItem?
    var locationReplayStopItem: NSMenuItem?
    init(control: VPhoneGuestControl) { self.control = control }
    func makeItem(_ title: String, action: Selector, symbol: String? = nil) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
    func menuSymbol(_ name: String) -> NSImage? { nil }
}

@MainActor
enum VPhoneAlert {
    static var messages: [String] = []
    static func present(title: String, message: String, style: NSAlert.Style) { messages.append(message) }
}

@main
struct GUILocationSelectionTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    @MainActor static func settle(_ menu: VPhoneMenuController) async {
        for _ in 0..<200 {
            await Task.yield()
            if menu.locationMenuItem?.isEnabled == true { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(false, "GUI source selection did not complete")
    }

    @MainActor static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for mode in ["fixed", "stream"] {
            for selection in ["preset", "replay", "host", "stop", "clear-failure", "helper-failure", "save-failure"] {
                let control = VPhoneGuestControl()
                let stateURL = temporary.appendingPathComponent("\(mode)-\(selection).json")
                let controller = VPhoneSystemLocationController(adapter: VPhoneOwnedLocationGuestAdapter(control: control),
                    stateStore: VPhoneSystemLocationStateStore(url: stateURL))
                let fix = VPhoneSystemLocationFix(producerSequence: 0, latitude: 31.2, longitude: 118.8,
                    altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 8, speed: 0, course: -1, timestamp: 1_700_000_000)
                if mode == "fixed" {
                    _ = try await controller.setFixed(owner: "automation", fix: fix, heartbeatSeconds: 60, persist: true)
                } else {
                    _ = try await controller.startStream(owner: "automation", watchdogSeconds: 60)
                    _ = try await controller.push(generation: controller.generation!, fix: fix)
                }
                var helperStarts = 0
                let provider = VPhoneLocationProvider(control: control, hostHelperLauncher: {
                    helperStarts += 1
                    if selection == "helper-failure" { throw CocoaError(.fileReadNoSuchFile) }
                })
                provider.automationLocationIsActive = { controller.requiresExplicitSourceSelection }
                provider.selectGUISource = { commit in try await controller.selectGUISource(commit) }
                let menu = VPhoneMenuController(control: control)
                menu.locationProvider = provider
                _ = menu.buildLocationSubmenu()
                menu.updateLocationCapability(available: true)
                var saved: [Bool] = []
                menu.onHostLocationSyncChange = {
                    if selection == "save-failure" { throw CocoaError(.fileWriteNoPermission) }
                    saved.append($0)
                }
                VPhoneAlert.messages = []
                let sender = NSMenuItem(title: "test", action: nil, keyEquivalent: "")
                sender.tag = 0
                switch selection {
                case "preset": menu.setLocationPreset(sender)
                case "replay": menu.startLocationReplay(sender)
                case "stop":
                    control.syncsHostLocation = true
                    menu.locationMenuItem?.state = .on
                    menu.toggleLocationSync()
                default:
                    control.failClear = selection == "clear-failure"
                    menu.toggleLocationSync()
                }
                await settle(menu)
                if selection == "clear-failure" {
                    check(controller.hasActiveSource, "failed clear must retain owned source")
                    check(saved.isEmpty && helperStarts == 0, "failed handoff must not enable or persist host forwarding")
                } else {
                    check(!controller.hasActiveSource, "\(mode) -> \(selection) must release host ownership")
                    check(!FileManager.default.fileExists(atPath: stateURL.path), "GUI takeover must remove persistence")
                    do {
                        let unowned = try control.owned.unowned { ["accepted": true] }
                        check(unowned["accepted"] as? Bool == true, "GUI must own guest simulation")
                    } catch {
                        check(false, "GUI guest write refused: \(error)")
                    }
                }
                check(control.drains == 1, "handoff must drain queued GUI updates")
                switch selection {
                case "preset":
                    check(control.lastLatitude == 37.334606, "preset must reach guest after owned clear")
                    check(VPhoneAlert.messages.isEmpty, "successful preset must not report an error")
                case "replay":
                    for _ in 0..<20 where control.lastLatitude == nil { await Task.yield() }
                    check(provider.isReplaying && control.lastLatitude == 37.334606, "replay must reach guest")
                    check(menu.locationReplayStartItem?.state == .on, "replay menu must reflect the established source")
                case "host":
                    check(helperStarts == 1 && saved == [true], "host forwarding must start and save once")
                    check(control.syncsHostLocation && menu.locationMenuItem?.state == .on, "host checkmark must follow success")
                case "stop":
                    check(helperStarts == 0 && saved == [false], "explicit off must persist after clearing owned source")
                    check(!control.syncsHostLocation && menu.locationMenuItem?.state == .off, "stop must update checkbox")
                default:
                    check(!VPhoneAlert.messages.isEmpty, "failed selection must report failure")
                    check(!control.syncsHostLocation && menu.locationMenuItem?.state == .off && saved.isEmpty,
                        "failed selection must not claim successful host sync")
                }
                provider.stopForwarding()
                provider.stopReplay()
                if controller.hasActiveSource { control.failClear = false; _ = try await controller.stop() }
            }
        }
        print("\(checks) GUI location checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
