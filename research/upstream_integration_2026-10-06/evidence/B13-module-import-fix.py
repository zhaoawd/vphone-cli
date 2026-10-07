from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
for name in ['OutputAcknowledgementTests.swift','OutputXPCTests.swift']:
 p=r/'tests/VPhoneHelperKitTests'/name;s=p.read_text().replace('import VPhoneLaunchpadKit','import VPhoneCore').replace('VPhoneLaunchpadLogWriter','VPhoneLogWriter');p.write_text(s)
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineOrigins.swift';s=p.read_text();p.write_text('import VPhoneCore\n\n'+s)
for p in (r/'tests/VPhoneLaunchpadKitTests').glob('*.swift'):
 s=p.read_text()
 if ('VPhoneLaunchpadMachineBinding' in s or 'VPhoneLaunchpadLogWriter' in s) and 'import VPhoneCore' not in s:
  p.write_text('import VPhoneCore\n'+s)
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineBinding.swift';s=p.read_text();a=s.index('    public static func persistHost(');b=s.index('\n}\nextension VPhoneMachineBinding.Snapshot',a);s=s[:a]+s[b:];p.write_text(s)
p=r/'tests/VPhoneLaunchpadKitTests/BindingPersistenceTests.swift';s=p.read_text().replace('VPhoneLaunchpadMachineBinding.persistHost','VPhoneMachineBinding.persistHost').replace('machine: path,','machine: path.url,');p.write_text(s)
