import Darwin
import Foundation
import IcliKit

/// Publishes one location for the app-side CoreLocation bridge. The VM's
/// locationd accepts simulation commands but can fail to deliver a fused fix.
enum GuestLocationSimulation {
    // Kept in contract with Shared/VPhoneLocationState.h and its app reader.
    static let directory = "/var/mobile/Library/SimulatedLocation"
    static let path = directory + "/location.json"
    static let maximumAge: Double = 5
    private static let backend = LocationDaemonBackend()

    struct Point: Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double

        var json: [String: Double] {
            [
                "latitude": latitude, "longitude": longitude, "altitude": altitude,
                "horizontal_accuracy": horizontalAccuracy, "vertical_accuracy": verticalAccuracy,
                "speed": speed, "course": course,
            ]
        }
    }

    static func set(_ point: Point) throws -> [String: Any] {
        guard point.latitude.isFinite, (-90 ... 90).contains(point.latitude),
              point.longitude.isFinite, (-180 ... 180).contains(point.longitude),
              point.altitude.isFinite, point.horizontalAccuracy.isFinite, point.horizontalAccuracy >= 0,
              point.verticalAccuracy.isFinite,
              point.verticalAccuracy >= 0 || point.verticalAccuracy == -1,
              point.speed.isFinite, point.course.isFinite
        else { throw GuestAPIError.invalidRequest("invalid location coordinates or accuracy") }

        try backend.set(point)
        return ["simulating": true, "delivery": "application_override", "location": point.json]
    }

    fileprivate static func publish(_ point: Point) throws {
        var state: [String: Any] = point.json
        state["generation"] = "guest_api"
        state["delivery_sequence"] = 0
        state["published_at"] = Date().timeIntervalSince1970
        let data = try JSONSerialization.data(withJSONObject: state)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        try writeAtomically(data)
    }

    static func clear() throws -> [String: Any] {
        try backend.clear()
        return ["simulating": false]
    }

    static func current(timeout: Double) throws -> [String: Any] {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let published = state["published_at"] as? Double,
           (-1 ... maximumAge).contains(Date().timeIntervalSince1970 - published),
           ["latitude", "longitude", "altitude", "horizontal_accuracy", "vertical_accuracy", "speed", "course"].allSatisfy({ state[$0] is NSNumber })
        {
            var result: [String: Any] = state
            result["simulated"] = true
            result["delivery"] = "application_override"
            return result
        }
        return try currentLocation(timeout: timeout)
    }

    private static func writeAtomically(_ data: Data) throws {
        let folder = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw GuestAPIError.operationFailed("could not open simulation directory") }
        defer { close(folder) }
        var attributes = stat()
        guard fstat(folder, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o022 == 0 else {
            throw GuestAPIError.operationFailed("simulation directory ownership or mode differs")
        }
        let temporary = ".location-" + UUID().uuidString
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw GuestAPIError.operationFailed("could not open simulated location: \(String(cString: strerror(errno)))")
        }
        var openFD = fd
        defer {
            if openFD >= 0 { close(openFD) }
            unlinkat(folder, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else {
                    throw GuestAPIError.operationFailed("could not write simulated location: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fchmod(fd, 0o644) == 0, close(fd) == 0 else {
            openFD = -1
            throw GuestAPIError.operationFailed("could not finish simulated location: \(String(cString: strerror(errno)))")
        }
        openFD = -1
        guard renameat(folder, temporary, folder, "location.json") == 0 else {
            throw GuestAPIError.operationFailed("could not publish simulated location: \(String(cString: strerror(errno)))")
        }
    }
}

/// Best-effort system simulation remains useful on guests whose locationd
/// publishes a fix. It cannot block application updates or route replay.
private final class LocationDaemonBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vphoned.location.simulation")
    private let publicationQueue = DispatchQueue(label: "vphoned.location.publication")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var publication: DispatchSourceTimer?

    func set(_ point: GuestLocationSimulation.Point) throws {
        lock.lock()
        do { try GuestLocationSimulation.publish(point) }
        catch { lock.unlock(); throw error }
        generation &+= 1
        let submitted = generation
        publication?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: publicationQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == submitted else { return }
            do { try GuestLocationSimulation.publish(point) }
            catch { NSLog("[location] application state refresh failed: %@", String(describing: error)) }
        }
        publication = timer
        timer.resume()
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let current = generation == submitted
            lock.unlock()
            guard current else { return }
            do {
                _ = try simulateLocation(
                    latitude: point.latitude, longitude: point.longitude,
                    altitude: point.altitude, horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy,
                    speed: point.speed >= 0 ? point.speed : nil,
                    course: point.course >= 0 ? point.course : nil,
                )
            } catch {
                NSLog("[location] system simulation unavailable: %@", String(describing: error))
            }
        }
    }

    func clear() throws {
        lock.lock()
        guard unlink(GuestLocationSimulation.path) == 0 || errno == ENOENT else {
            lock.unlock()
            throw GuestAPIError.operationFailed("could not clear simulated location: \(String(cString: strerror(errno)))")
        }
        generation &+= 1
        let submitted = generation
        publication?.cancel()
        publication = nil
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let current = generation == submitted
            lock.unlock()
            if current { _ = try? clearSimulatedLocation() }
        }
    }
}
