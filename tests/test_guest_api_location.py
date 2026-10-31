"""Run the actual Swift location publisher with an isolated directory/backend."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestAPILocationTests(unittest.TestCase):
    def test_api_point_stays_fresh_then_clear_cancels_publication(self):
        with tempfile.TemporaryDirectory(prefix='api-location-') as temporary:
            folder = Path(temporary)
            source = (ROOT / 'sources/VPhoneDaemon/Daemon/GuestLocationSimulation.swift').read_text()
            header = (ROOT / 'sources/VPhoneGuestComponents/Shared/VPhoneLocationState.h').read_text()
            directory = re.search(r'static let directory = "([^"]+)"', source).group(1)
            self.assertIn('"' + directory + '"', header)
            self.assertIn('#define VPHONE_LOCATION_STATE_MAX_AGE_SECONDS 5.0', header)
            # Only the import/backend and filesystem root are test substitutes.
            source = source.replace('import IcliKit\n', '').replace(json.dumps(directory), json.dumps(str(folder / 'state')))
            (folder / 'Actual.swift').write_text(source)
            (folder / 'Harness.swift').write_text('''
import Foundation
enum GuestAPIError: Error { case invalidRequest(String), operationFailed(String) }
func currentLocation(timeout: Double) throws -> [String: Any] { ["native": true] }
func simulateLocation(latitude: Double, longitude: Double, altitude: Double, horizontalAccuracy: Double,
                      verticalAccuracy: Double, speed: Double?, course: Double?) throws -> Bool { true }
func clearSimulatedLocation() throws -> Bool { true }
@main struct Harness {
    static func main() throws {
        let a = GuestLocationSimulation.Point(latitude: 31.2, longitude: 121.5, altitude: 20,
            horizontalAccuracy: 5, verticalAccuracy: -1, speed: 2, course: 90)
        _ = try GuestLocationSimulation.set(a)
        Thread.sleep(forTimeInterval: GuestLocationSimulation.maximumAge + 1.2)
        let first = try GuestLocationSimulation.current(timeout: 0)
        precondition(first["latitude"] as? Double == 31.2 && first["simulated"] as? Bool == true)
        let b = GuestLocationSimulation.Point(latitude: 30.25, longitude: 120.15, altitude: 35,
            horizontalAccuracy: 6, verticalAccuracy: 7, speed: 3, course: 120)
        _ = try GuestLocationSimulation.set(b)
        Thread.sleep(forTimeInterval: 1.2)
        precondition(try GuestLocationSimulation.current(timeout: 0)["latitude"] as? Double == 30.25)
        _ = try GuestLocationSimulation.clear()
        Thread.sleep(forTimeInterval: 1.2)
        precondition(!FileManager.default.fileExists(atPath: GuestLocationSimulation.path))
        precondition(try GuestLocationSimulation.current(timeout: 0)["native"] as? Bool == true)
    }
}
'''.replace('precondition(try GuestLocationSimulation.current(timeout: 0)["latitude"] as? Double == 30.25)',
            'let second = try GuestLocationSimulation.current(timeout: 0); precondition(second["latitude"] as? Double == 30.25)')
            .replace('precondition(try GuestLocationSimulation.current(timeout: 0)["native"] as? Bool == true)',
            'let cleared = try GuestLocationSimulation.current(timeout: 0); precondition(cleared["native"] as? Bool == true)'))
            compile_result = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                str(folder / 'Actual.swift'), str(folder / 'Harness.swift'), '-o', str(folder / 'check')],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(folder / 'check')], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
