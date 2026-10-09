from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/sources/VPhoneCore/VPhoneCreateResourceSnapshot.swift')
s=p.read_text().replace('''    package let romSource: URL
    package let sepromSource: URL''','''    package var romSource: URL { directory.appendingPathComponent("ROMs/AVPBooter.vresearch1.bin") }
    package var sepromSource: URL { directory.appendingPathComponent("ROMs/AVPSEPBooter.vresearch1.bin") }''',1)
s=s.replace('PATH tools, host SDK/compiler, Virtualization framework ROMs and JB compilation are external','PATH tools, host SDK/compiler and JB compilation are external',1)
s=s.replace('source.vphoned, cli, VPhoneResources.vmExecutable(executable: cli)]','source.vphoned, cli, VPhoneResources.vmExecutable(executable: cli), romSource, sepromSource]',1)
s=s.replace('''        let inputs = try inventory(roots)''','''        // Keep external ROM copies beside the sealed bundle so its signatures remain valid.
        roots += [(romSource, "ROMs/AVPBooter.vresearch1.bin"),
                  (sepromSource, "ROMs/AVPSEPBooter.vresearch1.bin")]
        let inputs = try inventory(roots)''',1)
s=s.replace('let entries = try inventory([(directory.appendingPathComponent("VPhone.bundle"), "VPhone.bundle")]).map(\\.entry)','let entries = try inventory(snapshotRoots(directory)).map(\\.entry)',1)
s=s.replace('return VPhoneCreateResourceSnapshot(directory: directory, source: source, manifest: manifest, romSource: romSource, sepromSource: sepromSource)','return VPhoneCreateResourceSnapshot(directory: directory, source: source, manifest: manifest)',1)
s=s.replace('''private init(directory: URL, source: VPhoneResources, manifest: Manifest, romSource: URL, sepromSource: URL) {
        self.romSource = romSource
        self.sepromSource = sepromSource''','''private init(directory: URL, source: VPhoneResources, manifest: Manifest) {''',1)
s=s.replace('''    public func fingerprint() throws -> String {
        try Self.digest(Self.inventory([(directory.appendingPathComponent("VPhone.bundle"), "VPhone.bundle")]).map(\\.entry))
    }''','''    private static func snapshotRoots(_ directory: URL) -> [(URL, String)] {
        [(directory.appendingPathComponent("VPhone.bundle"), "VPhone.bundle"),
         (directory.appendingPathComponent("ROMs"), "ROMs")]
    }

    public func fingerprint() throws -> String {
        try Self.digest(Self.inventory(Self.snapshotRoots(directory)).map(\\.entry))
    }''',1)
p.write_text(s)
