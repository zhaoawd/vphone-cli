import Foundation

@MainActor
@main struct OrientationHoldTests {
    static func main() async {
        let short = OrientationControl()
        let long = OrientationControl()
        let stopped = OrientationControl()
        for control in [short, long, stopped] {
            await control.probe()
            control.followOrientation(["degrees": NSNumber(value: 90), "device_degrees": NSNumber(value: 270)])
            control.foldAngle = 180
            control.foldPosition = "open"
            control.foldSweepSeconds = 0.5
        }

        var failed = 0
        var total = 0
        func check(_ name: String, _ passed: Bool) {
            total += 1
            if !passed {
                print("FAIL: \(name)")
                failed += 1
            }
        }
        var longUpdates: [VPhoneDisplayOrientation?] = []
        var shortUpdates: [VPhoneDisplayOrientation?] = []
        long.observeInterfaceOrientation { longUpdates.append($0) }
        short.observeInterfaceOrientation { shortUpdates.append($0) }

        let clock = ContinuousClock()
        let began = clock.now
        var disconnects = 0
        long.onDisconnect = { disconnects += 1 }
        long.setDisconnected()
        short.setDisconnected()
        stopped.setDisconnected()
        check("disconnect holds both directions without a portrait notification",
              !long.isConnected && long.interfaceOrientation == .landscapeLeft &&
                  long.deviceOrientation == .landscapeRight && longUpdates.isEmpty)
        check("fold state and guest capabilities clear immediately",
              long.foldAngle == nil && long.foldPosition == nil && long.foldSweepSeconds == 0 &&
                  long.guestCapabilities.isEmpty && disconnects == 1)
        stopped.stop()
        check("stopping during the hold clears both directions immediately",
              stopped.interfaceOrientation == nil && stopped.deviceOrientation == nil)

        await short.probe()
        check("reconnection preserves both directions",
              short.isConnected && short.interfaceOrientation == .landscapeLeft &&
                  short.deviceOrientation == .landscapeRight && shortUpdates.isEmpty)
        short.followOrientation(["degrees": NSNumber(value: 270), "device_degrees": NSNumber(value: 90)])

        let lateHealth = OrientationControl()
        lateHealth.delayHealth = true
        let probe = Task { await lateHealth.probe() }
        lateHealth.monitor = probe
        while lateHealth.pendingHealth == nil { await Task.yield() }
        lateHealth.stop()
        lateHealth.pendingHealth?.resume()
        await probe.value
        check("a stopped monitor cannot reconnect on a late health response", !lateHealth.isConnected)

        let lateRotation = OrientationControl()
        await lateRotation.probe()
        lateRotation.interfaceOrientation = .landscapeLeft
        lateRotation.delayRotation = true
        let rotation = Task { try? await lateRotation.rotate(toFirstOf: [.landscapeRight]) }
        while lateRotation.pendingRotation == nil { await Task.yield() }
        lateRotation.stop()
        lateRotation.pendingRotation?.resume()
        _ = await rotation.value
        check("a stopped rotation cannot restore the window direction", lateRotation.interfaceOrientation == nil)

        try? await clock.sleep(until: began.advanced(by: .seconds(3)))
        long.setDisconnected()
        check("repeated failure keeps the original orientation before expiry",
              disconnects == 1 && long.interfaceOrientation == .landscapeLeft && longUpdates.isEmpty)
        let deadline = began.advanced(by: .seconds(7))
        while long.interfaceOrientation != nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        check("a prolonged disconnect clears both directions once, after five seconds",
              began.duration(to: clock.now) >= .seconds(5) && clock.now < deadline &&
                  long.interfaceOrientation == nil && long.deviceOrientation == nil && longUpdates == [nil])
        check("the old timer does not clear the new reading after reconnect",
              short.interfaceOrientation == .landscapeRight && short.deviceOrientation == .landscapeLeft &&
                  shortUpdates == [.landscapeRight])
        short.stop()
        check("stopping while connected also clears both directions immediately",
              short.interfaceOrientation == nil && short.deviceOrientation == nil &&
                  shortUpdates == [.landscapeRight, nil])

        print("Orientation hold: \(total - failed)/\(total) passed")
        if failed != 0 { exit(1) }
    }
}
