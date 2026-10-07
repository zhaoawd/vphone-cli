from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/vphone-cli/VPhoneCLI.swift';s=p.read_text().replace('    var autoUpdateGuestBinaryURL: URL? { guestBinaryURL }','''    @Flag(help: "Connect to the existing classic daemon without offering a binary update")
    var noVphonedUpdate = false

    var autoUpdateGuestBinaryURL: URL? { bindingSha256 == nil && !noVphonedUpdate ? guestBinaryURL : nil }''');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text().replace('            let vphonedURL = cli.guestBinaryURL\n            if FileManager.default.fileExists(atPath: vphonedURL.path) {','            if let vphonedURL = cli.autoUpdateGuestBinaryURL, FileManager.default.fileExists(atPath: vphonedURL.path) {');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneVMLaunchCLI.swift';s=p.read_text().replace('        if !dfu && !noVphoned {','        if binding == nil && !dfu && !noVphoned {',1)
s=s.replace('var args = ["--config", bundle.configURL.path] + guestPayloadArguments(resources: resources) + apiProxyArguments()','var args = ["--config", bundle.configURL.path] + (binding == nil ? guestPayloadArguments(resources: resources) : ["--no-vphoned-update"]) + apiProxyArguments()');p.write_text(s)
