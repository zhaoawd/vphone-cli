"""Debug-only real DSC replay on an isolated copy; never writes the VM."""
import hashlib, json, os, plistlib, shutil, subprocess, sys
from pathlib import Path

r = Path.cwd(); sys.path.insert(0, str(r/'scripts'))
from patchers import cfw, cfw_patch_iomfb_swapend as swap, guest_undo
from patchers.volume_state import volume_read_only
out = r/'.build/t32-dyldreadonly-debug'
observation = json.loads((out/'source-result.json').read_text())
diagnostic = json.loads((r/'.build/t32-dsc-readonly-source/result.json').read_text())
image = r/'vm-t32-t33-dsc-20261018/.cfw_temp/CryptexSystemOS.dmg'
mount = out/'replay-readonly'; mount.mkdir(exist_ok=True)
work = out/'isolated-dsc'
os.environ['CFW_HOST_MNT'] = str(out)
def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
assert sha(image) == observation['cacheSHA256']
attached = False
try:
    subprocess.run(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-owners','on','-mountpoint',str(mount),str(image)],check=True)
    attached = True
    volume = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',str(mount)]))
    assert volume_read_only(volume) and volume['MountPoint'] == str(mount)
    if sys.argv[1:] != ['--use-existing-copy']:
        shutil.copytree(mount/'System/Library/Caches/com.apple.dyld', work)
    else:
        source = mount/'System/Library/Caches/com.apple.dyld'
        assert {p.name:sha(p) for p in source.iterdir()} == {p.name:sha(p) for p in work.iterdir()}
finally:
    if attached: subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True)
assert sha(image) == observation['cacheSHA256']
before = {p.name:sha(p) for p in work.iterdir()}
assert len(before) == len(observation['inventory'])
readonly = cfw._readonly_dsc_inputs(work)
assert set(readonly) == {p['name'] for p in observation['members']}
assert swap.patch_iomfb_swapend(str(work), target_size=diagnostic['targetSize']) == 1
assert cfw._readonly_dsc_inputs(work) == readonly
after = {p.name:sha(p) for p in work.iterdir()}
changed = [name for name in before if before[name] != after[name]]
assert changed == [diagnostic['member']], changed
assert before[diagnostic['member']] == diagnostic['memberSHA256']
pages = guest_undo.verify_code_pages(work/diagnostic['member'])
assert pages == diagnostic['verifiedCodePages']
with (work/diagnostic['member']).open('rb') as stream:
    stream.seek(diagnostic['fileOffset']); raw = stream.read(4)
instruction = list(swap._cs.disasm(raw, int(diagnostic['instructionAddress'],16)))
assert len(instruction) == 1 and swap._mov_reg_imm(instruction[0]) == ('w3',diagnostic['targetSize'])
result = dict(schemaVersion=1,state='passed',isolatedCopy=True,vmWritten=False,
    members=len(before),readonlyInputs=sorted(readonly),changedMembers=changed,
    before=before,after=after,verifiedCodePages=pages,sourceCacheUnchanged=True,
    sourceSize=diagnostic['sourceSize'],targetSize=diagnostic['targetSize'])
(out/'replay-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
