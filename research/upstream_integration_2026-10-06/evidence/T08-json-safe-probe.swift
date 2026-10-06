import Foundation

@main struct JSONSafeProbe {
    static func main() throws {
        let input: [String: Any] = [
            "nan": NSNumber(value: Double.nan), "inf": NSNumber(value: Double.infinity),
            "nested": [NSNumber(value: -Double.infinity), Data([0xff, 0x00]), Date(timeIntervalSince1970: 0)],
            "name": "中文/日本語/🙂", "finite": NSNumber(value: 12.5), "null": NSNull(),
        ]
        let safe = jsonSafe(input)
        guard JSONSerialization.isValidJSONObject(safe), let fields = safe as? [String: Any],
              fields["name"] as? String == "中文/日本語/🙂", fields["finite"] as? NSNumber == 12.5,
              fields["nan"] is String, fields["inf"] is String,
              let nested = fields["nested"] as? [Any], nested[0] is String,
              nested[1] as? String == "/wA=", nested[2] as? String == "1970-01-01T00:00:00Z",
              fields["null"] is NSNull else { throw NSError(domain: "JSONSafeProbe", code: 1) }
        _ = try JSONSerialization.data(withJSONObject: safe)
        print("IcliKit 0.7.16 jsonSafe: NaN/infinities, nested invalid-UTF8 Data, Date, Unicode, finite number, null: PASS (macOS only)")
    }
}
