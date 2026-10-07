from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineEdit.swift';s=p.read_text().replace('args += ["--startup-unlock"','arguments += ["--startup-unlock"');p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneBundleReport.swift';s=p.read_text().replace('    public let hardwareKeyboardEnabled: Bool?','    public let hardwareKeyboardEnabled: Bool?\n    public let unlockAtStartup: Bool?').replace('        self.hardwareKeyboardEnabled = bundle.manifest.hardwareKeyboardEnabled','        self.hardwareKeyboardEnabled = bundle.manifest.hardwareKeyboardEnabled\n        self.unlockAtStartup = bundle.manifest.unlockAtStartup');p.write_text(s)
