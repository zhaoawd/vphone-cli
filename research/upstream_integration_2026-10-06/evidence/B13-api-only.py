from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneDaemon/Daemon/main.swift';s=p.read_text();s=s.replace('let mode = vp_native_process_mode()','let apiOnly = ProcessInfo.processInfo.environment["VPHONE_API_ONLY"] == "1"\nlet mode = vp_native_process_mode()');s=s.replace('    vp_native_bootstrap_cached_binary()','    if !apiOnly { vp_native_bootstrap_cached_binary() }');s=s.replace('vp_vcam_start()\nGuestIrisinInstaller.refreshBootstrapOnStartup()','if !apiOnly {\n    vp_vcam_start()\n    GuestIrisinInstaller.refreshBootstrapOnStartup()\n}');p.write_text(s)
p=r/'sources/VPhoneDaemon/Daemon/GuestAPI.swift';s=p.read_text();s=s.replace('        if let pending = setupAssistantPending()', '''        if apiOnly, var capabilities = result["capabilities"] as? [String] {
            capabilities.removeAll { $0 == "camera" }
            result["capabilities"] = capabilities
        }
        if let pending = setupAssistantPending()''');s=s.replace('    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {','''    static func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        if apiOnly && (method.hasPrefix("camera.") || method == "agent.apply_update") {
            throw GuestAPIError.unsupportedMethod(method)
        }''');p.write_text(s)
p=r/'sources/VPhoneDaemon/Daemon/GuestAPI+SetupAssistant.swift';s=p.read_text().replace('return (value("SetupVersion") as? NSNumber)?.intValue ?? 0 < current','return ((value("SetupVersion") as? NSNumber)?.intValue ?? 0) < current');p.write_text(s)
