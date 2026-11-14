import Foundation

// Compile the actual upstream dispatcher and catalog against isolated handlers.
// These checks do not execute guest producers or prove their declared schemas.
enum ProbeMethod: String, GuestMethod {
    case spawn = "processes.spawn"
    case swipe = "input.swipe"
    case tap = "input.tap"
    case list = "files.list"
    case remove = "files.remove"

    var spec: MethodSpec {
        switch self {
        case .spawn:
            MethodSpec(.optional("timeout_ms", .number, "Timeout"), summary: "Spawn fixture")
        case .swipe:
            MethodSpec(.required("from", .array, "Start"), .required("to", .array, "End"), summary: "Swipe fixture")
        case .tap:
            MethodSpec(.required("x", .number, "X"), .required("y", .number, "Y"), summary: "Tap fixture")
        case .list:
            MethodSpec(summary: "List fixture", paged: .init(key: "entries", order: .strings))
        case .remove:
            MethodSpec(summary: "Remove fixture", force: .always("remove fixture"))
        }
    }
}

@main struct RPCContractPreflight {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        func save(_ name: String, _ value: Any) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: output.appendingPathComponent(name))
        }
        let upstream = GuestMethodArea.catalog(kinds)
        let duo = GuestDuoMethod.catalog()
        try save("upstream-catalog.json", upstream)
        try save("duo-catalog.json", duo)
        let rows = upstream["methods"] as! [[String: Any]]
        let names = rows.map { $0["name"] as! String }
        expect(Set(names).count == names.count, "Duplicate upstream method")
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as! String, $0) })
        let localRows = duo["methods"] as! [[String: Any]]
        let localOnly = localRows.map { $0["name"] as! String }.filter { byName[$0] == nil }.sorted()
        // Record differences, without treating an upstream declaration as proof
        // that the Duo producer changed. Description wording is not compared.
        func normalized(_ row: [String: Any], _ key: String) -> NSArray {
            let fields = row[key] as? [[String: Any]] ?? []
            return fields.map { field -> [String: Any] in
                var value: [String: Any] = [:]
                for name in ["name", "type", "required"] { value[name] = field[name] }
                if key == "result" {
                    value["nullable"] = field["nullable"] ?? false
                    value["open"] = field["open"] ?? false
                }
                return value
            }.sorted { ($0["name"] as! String) < ($1["name"] as! String) } as NSArray
        }
        let differences: [[String: Any]] = localRows.compactMap { row in
            let name = row["name"] as! String
            guard let remote = byName[name] else { return ["name": name, "missing_upstream": true] }
            let fields = ["params", "result"].filter { !normalized(row, $0).isEqual(normalized(remote, $0)) }
            return fields.isEmpty ? nil : ["name": name, "differing_fields": fields]
        }
        try save("catalog-differences.json", differences.map { difference -> [String: Any] in
            let name = difference["name"] as! String
            return ["name": name, "duo": localRows.first { $0["name"] as? String == name }!,
                    "upstream": byName[name] ?? [:]]
        })
        var upstreamRefusesNever = false
        do { _ = try GuestMethodArea.admit(DeviceMethod.displayAutoLockSet.spec, ["never": true]) }
        catch let error as GuestAPIError { upstreamRefusesNever = error.code == "invalid_param" }
        expect(upstreamRefusesNever, "Pinned upstream admission no longer reproduces the Duo never incompatibility")
        var calls = 0
        let area = GuestMethodArea.make(ProbeMethod.self) { method, params in
            calls += 1
            if method == .list { return ["entries": ["c", "a", "b"], "count": 3] }
            return params
        }
        func dispatch(_ method: String, _ params: [String: Any], observer: () throws -> [String: Any]? = { nil }) throws -> [String: Any] {
            try GuestMethodArea.dispatch([area], method: method, params: params, observer: observer)
        }
        func refusal(_ method: String, _ params: [String: Any], code: String) -> Bool {
            do { _ = try dispatch(method, params); return false }
            catch let error as GuestAPIError { return error.code == code }
            catch { return false }
        }
        let legacy = try dispatch("process.spawn", ["timeout_seconds": 2])
        expect((legacy["timeout_ms"] as? NSNumber)?.intValue == 2000, "Legacy method/seconds conversion")
        let canonical = try dispatch("processes.spawn", ["timeout_ms": 700, "timeout_seconds": 2])
        expect((canonical["timeout_ms"] as? NSNumber)?.intValue == 700, "Canonical timeout must win")
        expect(canonical["timeout_seconds"] == nil, "Legacy timeout must be removed before admission")
        let swipe = try dispatch("input.swipe", ["x1": 1, "y1": 2, "x2": 3, "y2": 4])
        expect((swipe["from"] as? [Int]) == [1, 2] && (swipe["to"] as? [Int]) == [3, 4], "Legacy swipe conversion")
        let mixedSwipeRefused = refusal("input.swipe", ["from": [1, 2], "to": [3, 4], "x1": 1, "y1": 2, "x2": 3, "y2": 4], code: "invalid_param")
        let before = calls
        expect(refusal("input.tap", ["x": 1, "y": 2, "typo": 1], code: "invalid_param"), "Unknown param must fail")
        expect(refusal("input.tap", ["x": 1, "y": 2, "observe": "true"], code: "invalid_param"), "String observe must fail")
        expect(refusal("input.tap", ["x": 1, "y": 2, "observe_delay_ms": 5001], code: "invalid_param"), "Observe delay upper bound")
        expect(calls == before, "Invalid params must fail before the action")
        expect(refusal("files.remove", [:], code: "force_required"), "Unforced destructive call")
        _ = try dispatch("files.remove", ["force": true])
        expect(calls == before + 1, "Forced action should execute exactly once")
        let unobserved = try dispatch("input.tap", ["x": 1, "y": 2])
        expect(unobserved["observed"] == nil, "Default reply must not acquire observed")
        let observed = try dispatch("input.tap", ["x": 1, "y": 2, "observe": true, "observe_delay_ms": 0]) { ["frontmost_bundle_id": "fixture"] }
        expect((observed["observed"] as? [String: String])?["frontmost_bundle_id"] == "fixture", "Observation must be returned")
        expect(observed["observe"] == nil && observed["observe_delay_ms"] == nil, "Observe params must not reach handler")
        let failedObservation = try dispatch("input.tap", ["x": 1, "y": 2, "observe": true, "observe_delay_ms": 0]) { throw GuestAPIError.unavailable("fixture") }
        expect((failedObservation["observed"] as? [String: String])?["observe_error"] != nil, "Observation failure must preserve action success")
        expect(refusal("unknown.method", [:], code: "not_found"), "Unknown method code")
        let page = try dispatch("files.list", ["limit": 2])
        expect(page["entries"] as? [String] == ["a", "b"], "Sorted first page")
        expect(page["total"] as? Int == 3 && page["truncated"] as? Bool == true, "First page metadata")
        expect(page["count"] as? Int == 2 && page["next_cursor"] as? String == "2", "Page count/cursor")
        let end = try dispatch("files.list", ["limit": 2, "cursor": "2"])
        expect(end["entries"] as? [String] == ["c"] && end["next_cursor"] == nil, "Last page")
        expect(refusal("files.list", ["limit": 0], code: "invalid_param"), "Zero page size")
        expect(refusal("files.list", ["limit": true], code: "invalid_param"), "Boolean page size")
        expect(refusal("files.list", ["cursor": "4"], code: "invalid_param"), "Cursor past list")
        let summary: [String: Any] = [
            "checks": checks, "upstream_methods": rows.count, "duo_catalog_methods": localRows.count,
            "local_only_catalog_methods": localOnly, "catalog_differences": differences,
            "mixed_swipe_names_refused": mixedSwipeRefused,
            "duo_never_refused_by_upstream_admission": upstreamRefusesNever,
            "scope": "upstream declarations/admission/paging with isolated handlers; no guest execution",
        ]
        try save("summary.json", summary)
        print("RPC contract preflight: \(checks)/\(checks) checks passed; \(rows.count) upstream methods, \(localRows.count) Duo catalog methods; \(differences.count) differing declarations")
    }
}
