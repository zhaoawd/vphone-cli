import Foundation

@main struct HealthProbeTests {
    @MainActor static func main() async {
        let ok: Result<VPhoneHTTPResponse, ProbeFailure> = .success(.init(status: 200))
        let fail: Result<VPhoneHTTPResponse, ProbeFailure> = .failure(.disconnected)
        var failures = 0
        let cases: [(String, Bool, [Result<VPhoneHTTPResponse, ProbeFailure>], Int, Int?)] = [
            ("connected success", true, [ok], 1, 200),
            ("initial success", false, [ok], 1, 200),
            ("transient failure", true, [fail, ok], 2, 200),
            ("persistent failure", true, [fail, fail], 2, nil),
            ("initial failure", false, [fail], 1, nil),
            ("HTTP failure is not a transport retry", true, [.success(.init(status: 503))], 1, 503),
        ]
        for (name, connected, replies, calls, status) in cases {
            let probe = Probe(connected: connected, replies: replies)
            let actual = try? await probe.request()
            if probe.calls != calls || actual?.status != status {
                print("FAIL: \(name): calls=\(probe.calls), status=\(String(describing: actual?.status))")
                failures += 1
            }
        }
        print("Health probe: \(cases.count - failures)/\(cases.count) passed")
        if failures != 0 { exit(1) }
    }
}
