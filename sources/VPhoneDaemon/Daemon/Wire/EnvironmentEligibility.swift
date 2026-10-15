import Foundation
import Darwin

/// Read-only qualification of an existing regular/v2 installation. Signature
/// evidence is Mach-O load-command/blob structure, not OS signature validation.
/// Host frozen-plan and current-Bundle verification are independently required.
struct EnvironmentEligibility {
    let root: URL
    let libraries: [String]

    func inspect(runningDaemonSHA256: String) -> [String: Any] {
        var reasons: [String] = []
        func file(_ path: String) -> URL { root.appendingPathComponent(path) }
        func regular(_ path: String) -> Data? {
            let url = file(path)
            guard EnvironmentTransaction.identity(atPath: url.path) != nil else { return nil }
            return try? Data(contentsOf: url)
        }
        func exists(_ path: String) -> Bool { var info = stat(); return lstat(file(path).path, &info) == 0 }
        func plist(_ path: String) -> [String: Any]? {
            guard let data = regular(path) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        guard let image = regular("sbin/launchd"), let loader = Self.inspectMachO(image) else {
            return ["eligible": false, "mode": "unknown", "reasons": ["launchd Mach-O is unreadable or malformed"]]
        }
        let custom = loader.loads.filter { !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("/System/") }
        if custom != ["/vh"] { reasons.append("launchd custom load commands differ from /vh") }
        if !loader.signature { reasons.append("launchd has no bounded code-signature blob") }
        if exists("b") { reasons.append("classic bootstrap /b is present") }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file("vh").path)) != "/usr/lib/launchdhook-vphone.dylib" {
            reasons.append("/vh does not name the installed launchdhook")
        }
        if regular("System/Library/xpc/launchd.plist.bak") == nil { reasons.append("completed CFW install marker is absent") }
        var hashes: [String: String] = [:]
        for name in libraries {
            let path = "usr/lib/" + name
            guard let bytes = regular(path), Self.inspectMachO(bytes)?.signature == true,
                  let hash = EnvironmentTransaction.sha256(atPath: file(path).path) else {
                reasons.append("installed library is absent, linked or has no bounded code-signature blob: " + name)
                continue
            }
            hashes[name] = hash
        }
        let daemonPath = "usr/bin/vphoned-api"
        let daemonHash = regular(daemonPath).flatMap { _ in EnvironmentTransaction.sha256(atPath: file(daemonPath).path) }
        if daemonHash != runningDaemonSHA256 || regular(daemonPath).flatMap(Self.inspectMachO)?.signature != true {
            reasons.append("installed API daemon differs from the running daemon or is malformed")
        }
        let jobPath = "/System/Library/LaunchDaemons/vphoned-api.plist"
        let job = plist(String(jobPath.dropFirst()))
        if job?["Label"] as? String != "com.vphone.vphoned.api"
            || job?["ProgramArguments"] as? [String] != ["/usr/bin/vphoned-api"]
            || (job?["EnvironmentVariables"] as? [String: String])?["VPHONED_VCAM"] != "off" {
            reasons.append("API launch daemon identity differs from the v2 profile")
        }
        if (plist("System/Library/xpc/launchd.plist")?["LaunchDaemons"] as? [String: Any])?[jobPath] == nil {
            reasons.append("API launch daemon key is absent")
        }
        let marker = "var/root/Library/Caches/vphoned.api-v2"
        if exists(marker), regular(marker).flatMap({ String(data: $0, encoding: .utf8) }) != runningDaemonSHA256 {
            reasons.append("cached daemon marker is unknown or stale")
        }
        if exists(marker + ".pending") { reasons.append("cached daemon activation is pending") }
        return ["eligible": reasons.isEmpty, "mode": reasons.isEmpty ? "regular-v2" : "unknown",
                "daemon_sha256": daemonHash ?? NSNull(), "libraries": hashes,
                "launchd_sha256": EnvironmentTransaction.sha256(atPath: file("sbin/launchd").path) ?? NSNull(),
                "launchd_custom_loads": custom, "signature_evidence": "load_command_and_blob_bounds_only",
                "reasons": reasons]
    }

    static func inspectMachO(_ data: Data) -> (loads: [String], signature: Bool)? {
        let bytes = [UInt8](data)
        func u32(_ at: Int, big: Bool = false) -> UInt32? {
            guard at >= 0, at <= bytes.count - 4 else { return nil }
            let value = bytes[at..<at+4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return big ? value : value.byteSwapped
        }
        guard bytes.count >= 32, u32(0) == 0xfeedfacf, let count = u32(16), let size = u32(20),
              size <= bytes.count - 32, count <= size / 8 else { return nil }
        var offset = 32, loads: [String] = [], signature = false
        let end = 32 + Int(size)
        for _ in 0..<count {
            guard let command = u32(offset), let length = u32(offset+4), length >= 8, Int(length) <= end-offset else { return nil }
            if [UInt32(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023].contains(command) {
                guard length >= 24, let name = u32(offset+8), name >= 24, name < length else { return nil }
                let region = bytes[offset+Int(name)..<offset+Int(length)]
                guard let zero = region.firstIndex(of: 0), let value = String(bytes: region[..<zero], encoding: .utf8) else { return nil }
                loads.append(value)
            }
            if command == 0x1d {
                guard length == 16, let start = u32(offset+8), let size = u32(offset+12), size >= 12,
                      start >= end, Int(start) <= bytes.count, Int(size) <= bytes.count-Int(start),
                      u32(Int(start), big: true) == 0xfade0cc0,
                      u32(Int(start)+4, big: true) == size,
                      let entries = u32(Int(start)+8, big: true), entries <= (size-12)/8 else { return nil }
                signature = true
            }
            offset += Int(length)
        }
        guard offset == end else { return nil }
        return (loads, signature)
    }
}
