import Foundation

private enum Fixture: String, GuestMethod {
    case spawn = "processes.spawn", unlock = "screen.unlock", script = "script.eval"
    case current = "location.current", wait = "ui.wait", gone = "ui.wait_gone"
    case settle = "setup.settle", swipe = "input.swipe"
    var spec: MethodSpec {
        switch self {
        case .swipe: MethodSpec(.required("from", .array, "Start"), .required("to", .array, "End"), summary: "Fixture")
        case .settle: MethodSpec(.optional("timeout_ms", .number, "Timeout"), .optional("poll_ms", .number, "Poll"), summary: "Fixture")
        default: MethodSpec(.optional("timeout_ms", .number, "Timeout"), summary: "Fixture")
        }
    }
}

@main enum RPCCompatibilityTests {
    static func main() {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL \(label)") }
        }
        let area = GuestMethodArea.make(Fixture.self) { _, params in params }
        func call(_ method: String, _ params: [String: Any]) -> [String: Any] {
            do { return try GuestMethodArea.dispatch([area], method: method, params: params) }
            catch { print("REFUSAL \(method): \(error)"); return [:] }
        }
        let aliases = [("process.spawn", "timeout_seconds"), ("processes.spawn", "timeout_seconds"),
                       ("screen.unlock", "timeout"), ("script.eval", "timeout"), ("location.current", "timeout"),
                       ("ui.wait", "timeout"), ("ui.wait_gone", "timeout"), ("setup.settle", "timeout_s")]
        for (method, old) in aliases {
            let converted = call(method, [old: 1.5])
            check((converted["timeout_ms"] as? NSNumber)?.doubleValue == 1500, "\(method) seconds converted")
            check(converted[old] == nil, "\(method) alias removed")
            let mixed = call(method, [old: 9, "timeout_ms": 250])
            check((mixed["timeout_ms"] as? NSNumber)?.doubleValue == 250, "\(method) new value wins")
            check(mixed[old] == nil, "\(method) shadowed alias removed")
        }
        let boolean = call("screen.unlock", ["timeout": true])["timeout_ms"] as? NSNumber
        check(boolean.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true, "legacy Boolean is not converted to milliseconds")
        let poll = call("setup.settle", ["poll_s": 2, "poll_ms": 1000])
        check(poll["poll_ms"] as? Int == 1000 && poll["poll_s"] == nil, "poll_ms wins and alias removed")
        let old: [String: Any] = ["x1": 1, "y1": 2, "x2": 3, "y2": 4]
        let swipe = call("input.swipe", old)
        check(swipe["from"] as? [Int] == [1, 2] && swipe["to"] as? [Int] == [3, 4], "legacy swipe points")
        var mixed = old; mixed["from"] = [5, 6]; mixed["to"] = [7, 8]
        let new = call("input.swipe", mixed)
        check(new["from"] as? [Int] == [5, 6] && new["to"] as? [Int] == [7, 8], "new swipe points win")
        check(["x1", "y1", "x2", "y2"].allSatisfy { new[$0] == nil }, "shadowed swipe aliases removed")
        do {
            _ = try GuestMethodArea.dispatch([area], method: "screen.unlock", params: ["unknown": 1])
            check(false, "unknown field refused")
        } catch let error as GuestAPIError { check(error.code == "invalid_param", "unknown field coded") }
        catch { check(false, "unknown field error type") }
        print("RPC compatibility: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
