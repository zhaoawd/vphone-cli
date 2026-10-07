from pathlib import Path
import json
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadCoreBundle.swift';s=p.read_text();start=s.index('// MARK: - Version names');end=s.index('// MARK: - Receipt');block=s[start:end].replace('VPhoneLaunchpadCoreBundleVersion','VPhoneCoreBundleVersion');(r/'sources/VPhoneCore/VPhoneCoreBundleVersion.swift').write_text('import Foundation\n\n'+block);s=s[:start]+'import VPhoneCore\n\npublic typealias VPhoneLaunchpadCoreBundleVersion = VPhoneCoreBundleVersion\n\n'+s[end:];p.write_text(s)
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineBinding.swift';s=p.read_text().replace('VPhoneLaunchpadMachineBinding','VPhoneMachineBinding').replace('VPhoneLaunchpadCoreBundleVersion','VPhoneCoreBundleVersion').replace('VPhoneLaunchpadError','VPhoneMachineBindingError').replace('VPhoneLaunchpadMachinePath','URL').replace('machine.url','machine').replace('    static func snapshot(_ machine: URL, afterRead:', '    package static func snapshot(_ machine: URL, afterRead:');(r/'sources/VPhoneCore/VPhoneMachineBinding.swift').write_text(s+'''\npublic struct VPhoneMachineBindingError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
''');p.write_text('''import Foundation
import VPhoneCore

public typealias VPhoneLaunchpadMachineBinding = VPhoneMachineBinding

extension VPhoneMachineBinding {
    public static func snapshot(_ machine: VPhoneLaunchpadMachinePath) throws -> Snapshot? { try snapshot(machine.url) }
    static func snapshot(_ machine: VPhoneLaunchpadMachinePath, afterRead: () throws -> Void) throws -> Snapshot? {
        try snapshot(machine.url, afterRead: afterRead)
    }
    public static func load(_ machine: VPhoneLaunchpadMachinePath) -> Read { load(machine.url) }
    public static func persistHost(_ version: String, machine: VPhoneLaunchpadMachinePath,
                                  expected: Snapshot?, firstMigrationBackup: URL? = nil) throws {
        try persistHost(version, machine: machine.url, expected: expected, firstMigrationBackup: firstMigrationBackup)
    }
}
extension VPhoneMachineBinding.Snapshot {
    public func matches(_ machine: VPhoneLaunchpadMachinePath) -> Bool { matches(machine.url) }
}
''')
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadBindingPersistence.swift';s=p.read_text().replace('import VPhoneCore\n','').replace('VPhoneLaunchpadMachineBinding','VPhoneMachineBinding').replace('VPhoneLaunchpadMachinePath','URL').replace('machine.url','machine').replace('VPhoneLaunchpadError','VPhoneMachineBindingError');(r/'sources/VPhoneCore/VPhoneMachineBindingPersistence.swift').write_text(s);p.unlink()
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadLogWriter.swift';s=p.read_text().replace('VPhoneLaunchpadLogWriter','VPhoneLogWriter').replace('    init(url: URL, handle:', '    package init(url: URL, handle:').replace('VPhoneLaunchpadError("Output arrived after log completion")','NSError(domain: "VPhoneLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output arrived after log completion"])');(r/'sources/VPhoneCore/VPhoneLogWriter.swift').write_text(s);p.write_text('import VPhoneCore\n\npublic typealias VPhoneLaunchpadLogWriter = VPhoneLogWriter\n')
for name in ['VPhoneHelperClient.swift','VPhoneHelperOutput.swift','VPhoneHelperService.swift']:
 p=r/'sources/VPhoneHelperKit'/name;s=p.read_text().replace('import VPhoneLaunchpadKit','import VPhoneCore').replace('VPhoneLaunchpadLogWriter','VPhoneLogWriter').replace('VPhoneLaunchpadCoreBundleVersion','VPhoneCoreBundleVersion');p.write_text(s)
for name in ['VPhoneVMLaunchCLI.swift','VPhoneVMBindingCLI.swift','VPhoneAppDelegate.swift']:
 p=r/'sources/vphone-cli'/name;s=p.read_text().replace('import VPhoneLaunchpadKit\n','').replace('VPhoneLaunchpadMachineBinding','VPhoneMachineBinding').replace('VPhoneLaunchpadCoreBundleVersion','VPhoneCoreBundleVersion').replace('VPhoneLaunchpadError','VPhoneMachineBindingError')
 if name=='VPhoneVMLaunchCLI.swift':
  s=s.replace('VPhoneLaunchpadMachinePath(libraryRoot: lib.library.root.path, name: name)','bundle.url').replace('machine: VPhoneLaunchpadMachinePath','machine: URL')
 elif name=='VPhoneVMBindingCLI.swift':s=s.replace('VPhoneLaunchpadMachinePath(libraryRoot: lib.library.root.path, name: name)','try lib.library.bundle(named: name).url')
 else:s=s.replace('VPhoneLaunchpadMachinePath(libraryRoot: directory.deletingLastPathComponent().path,\n                                                    name: directory.lastPathComponent)','directory')
 p.write_text(s)
p=r/'Package.swift';s=p.read_text().replace('"VPhoneHelperKit", dependencies: ["VPhoneBundleStore", "VPhoneLaunchpadKit"]','"VPhoneHelperKit", dependencies: ["VPhoneBundleStore", "VPhoneCore"]').replace('                "VPhoneLaunchpadKit",\n','');p.write_text(s)
p=r/'sources/VPhoneLaunchpad/Localizable.xcstrings';x=json.loads(p.read_text());key='Unlock at Startup (requires API listener)';x['strings'][key]={'localizations':{'en':{'stringUnit':{'state':'translated','value':key}},'zh-Hans':{'stringUnit':{'state':'translated','value':'启动时解锁（需要 API 监听器）'}}}};x['strings']=dict(sorted(x['strings'].items()));p.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n')
