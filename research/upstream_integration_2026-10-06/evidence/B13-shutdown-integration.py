from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/sources/vphone-cli/VPhoneAppDelegate.swift')
s=p.read_text().replace('guestShellAvailable: control?.canHaltGuest ?? false,','guestShellAvailable: apiCanShutdown || (control?.canHaltGuest ?? false),')
a='''                if await self.control?.haltGuest() != true {
                    self.fallBackFromGuestCommand(vm: vm)
                }'''
b='''                let api: (() async throws -> Bool)? = self.apiCanShutdown ? {
                    guard let session = self.apiSession else { return false }
                    let reply = try await session.call("system.shutdown", params: ["force": .bool(true)], requiring: "system_shutdown")
                    return { if case let .object(fields) = reply { return fields["accepted"] == .bool(true) }; return false }()
                } : nil
                let request = VPhoneGuestShutdown(api: api, classic: { [weak self] in
                    guard let self, !self.shutdownPlan.forceStopRequested else { return false }
                    return await self.control?.haltGuest() == true
                }, running: { [weak self] in self?.vm?.isRunning == true })
                let result = await request.request()
                print("[vphone] guest shutdown request: \\(result); awaiting VM stop")
                if result == .frameworkRequired { self.fallBackFromGuestCommand(vm: vm) }'''
assert a in s;s=s.replace(a,b)
i=s.index('    /// SIGINT: ask the guest');s=s[:i]+'''    private var apiCanShutdown: Bool {
        apiSession?.snapshot.state == .ready && apiSession?.snapshot.health?.capabilities.contains("system_shutdown") == true
    }

'''+s[i:];p.write_text(s)
