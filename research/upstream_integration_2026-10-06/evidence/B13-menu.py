from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/vphone-cli/VPhoneMenuController.swift';s=p.read_text().replace('    var onFilesPressed:', '''    var onStop: (() -> Void)?
    var onManualUnlock: (() -> Void)?
    var onStartupUnlockChanged: ((Bool) throws -> Void)?
    var startupUnlockItem: NSMenuItem?
    var manualUnlockItem: NSMenuItem?
    var onFilesPressed:''',1);s=s.replace('        appMenu.addItem(NSMenuItem.separator())\n        appMenu.addItem(', '''        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeItem("Stop VM", action: #selector(stopVM)))
        let manual = makeItem("Unlock Screen…", action: #selector(unlockScreen))
        manual.isEnabled = false
        manualUnlockItem = manual
        appMenu.addItem(manual)
        let startup = makeItem("Unlock at Startup", action: #selector(toggleStartupUnlock))
        startup.isEnabled = false
        startupUnlockItem = startup
        appMenu.addItem(startup)
        appMenu.addItem(''',1)
s += '''
extension VPhoneMenuController {
    @objc private func stopVM() { onStop?() }
    @objc private func unlockScreen() { onManualUnlock?() }
    @objc private func toggleStartupUnlock() {
        guard let item = startupUnlockItem, let change = onStartupUnlockChanged else { return }
        let enabled = item.state != .on
        do { try change(enabled); item.state = enabled ? .on : .off }
        catch { let alert = NSAlert(); alert.messageText = "Unable to save startup unlock"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
}
''';p.write_text(s)
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text();needle='            mc.vm = vm';s=s.replace(needle,'''            mc.onStop = { [weak self] in self?.handleInterrupt() }
            mc.startupUnlockItem?.isEnabled = startupUnlock != nil
            mc.startupUnlockItem?.state = (cli.unlockAtStartup || (try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock)) ? .on : .off
            mc.onStartupUnlockChanged = { [weak self] enabled in
                guard let self, self.vmLock != nil, let unlock = self.startupUnlock else { throw VPhoneLaunchpadError("Startup unlock requires an API listener") }
                let manifest = try VPhoneVirtualMachineManifest.load(from: options.configURL)
                try manifest.updating(unlockAtStartup: enabled).write(to: options.configURL)
                unlock.setEnabled(enabled)
            }
            mc.onManualUnlock = { [weak self] in
                guard let self, let session = self.apiSession else { return }
                Task { @MainActor in
                    let failure: String? = await self.hostInputQueue.run(cancelled: "Unlock cancelled") {
                        do { _ = try await session.call("screen.unlock", params: ["timeout": .number(60)], requiring: "screen_unlock"); return nil }
                        catch { return error.localizedDescription }
                    }
                    if let failure { let alert = NSAlert(); alert.messageText = "Screen unlock failed"; alert.informativeText = failure; alert.runModal() }
                }
            }
            if let session = apiSession {
                let unlock = startupUnlock
                session.onSnapshotChange = { [weak mc, weak unlock] snapshot in
                    unlock?.observe(snapshot)
                    mc?.manualUnlockItem?.isEnabled = snapshot.state == .ready && snapshot.health?.capabilities.contains("screen_unlock") == true
                }
                mc.manualUnlockItem?.isEnabled = session.snapshot.state == .ready && session.snapshot.health?.capabilities.contains("screen_unlock") == true
            }
            mc.vm = vm''',1)
# Evaluate the persisted value outside throwing || autoclosure.
s=s.replace('            mc.startupUnlockItem?.state = (cli.unlockAtStartup || (try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock)) ? .on : .off','            let savedStartupUnlock = try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock\n            mc.startupUnlockItem?.state = (cli.unlockAtStartup || savedStartupUnlock) ? .on : .off')
i=s.index('    func applicationWillTerminate');s=s[:i]+'''    @MainActor
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard vm?.isRunning == true else { return .terminateNow }
        handleInterrupt()
        return .terminateCancel
    }

'''+s[i:];p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneVirtualMachineManifest.swift';s=p.read_text().replace('            try data.write(to: url)','            try data.write(to: url, options: .atomic)');p.write_text(s)
