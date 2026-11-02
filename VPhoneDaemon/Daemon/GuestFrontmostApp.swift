import Foundation
import IcliKit
import VphonedNative

/// Returns the frontmost application. When no application has a focal assertion
/// (e.g. on the SpringBoard Home screen), verifies that the device is unlocked,
/// screen is on, RunningBoard has active handles, and SpringBoard is alive.
public func frontmostApp() -> [String: Any] {
    let raw = IcliLaunch.frontmostApp()
    if raw["verified"] as? Bool == true {
        return raw
    }
    let bundle = raw["bundle_id"] as? String ?? ""
    guard bundle == "com.apple.springboard" || bundle == "com.apple.PineBoard" else {
        return raw
    }
    let source = raw["source"] as? String ?? ""
    guard source == "unavailable" || source == "springboard_query" else {
        return raw
    }
    let rb = raw["runningboard"] as? [String: Any] ?? [:]
    let reason = rb["reason"] as? String ?? ""
    guard reason == "no_focal_app" else {
        return raw
    }
    let focal = rb["focal"] as? [String] ?? []
    guard focal.isEmpty else {
        return raw
    }
    let handles = (rb["handles"] as? NSNumber)?.intValue ?? 0
    guard handles > 0 else {
        return raw
    }
    let lock = lockState()
    guard lock["locked"] as? Bool != true, lock["screen_off"] as? Bool != true else {
        return raw
    }
    let pid = vp_springboard_pid()
    guard pid > 1 else {
        return raw
    }
    var result = raw
    result["verified"] = true
    result["source"] = "runningboard"
    result["pid"] = Int(pid)
    return result
}
