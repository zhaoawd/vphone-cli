"""仅向研究副本的事务副本安装默认 API；保留旧 Disk.img 和 classic 载荷。"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import time

HERE = Path(__file__).resolve().parent
CODE = HERE.parents[4]
sys.path.insert(0, str(CODE / 'scripts'))
import cfw_disk_txn as txn
import cfw_env_update as disk
VM = Path('/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010')
GUEST = CODE / '.build/research-b38/default/vphone-cli.app/Contents/Resources/guest-resources'
assert sys.argv[1:] in (['--check'], ['--run'])

def space():
    st = os.statvfs(VM)
    value = st.f_bavail * st.f_frsize
    assert value >= 5 * 1024**3, 'STOP: disk below 5 GiB'
    return value

def command(args):
    space()
    result = subprocess.run(args, capture_output=True, timeout=30, check=True)
    if result.stderr: print(result.stderr.decode(errors="replace"), file=sys.stderr)
    return result.stdout

def sha(path):
    data = (b"symlink:" + os.readlink(path).encode()) if path.is_symlink() else path.read_bytes()
    return hashlib.sha256(data).hexdigest()

expected = json.loads((HERE / 'default-artifact.json').read_text())
assert sha(GUEST / 'api/vphoned') == expected['api_sha256']
job = plistlib.loads((GUEST / 'api/vphoned.plist').read_bytes())
assert job['ProgramArguments'] == ['/usr/libexec/vphoned-api']
assert job['EnvironmentVariables'] == {'VPHONE_DISABLE_CAMERA':'1'}
assert VM.name == 'vm-roothide-b33-20261010' and not VM.is_symlink()
space()
if sys.argv[1:] == ['--check']:
    print(json.dumps({'vm':str(VM), 'sha256':expected['api_sha256'], 'changes':['/usr/libexec/vphoned-api', '/System/Library/LaunchDaemons/vphoned-api.plist', '/System/Library/xpc/launchd.plist (one additional entry)'], 'transaction':'existing cfw_disk_txn; previous disk retained', 'new_snapshot_flip':False, 'classic_update':False}))
    sys.exit(0)
assert os.geteuid() == 0
uid, gid = os.stat(HERE).st_uid, os.stat(HERE).st_gid
lock = os.open(VM, os.O_RDONLY | os.O_DIRECTORY)
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
os.environ['VPHONE_VM_LOCK_FD'] = str(lock)
fd = os.open(VM / 'Disk.img', os.O_RDONLY | os.O_NOFOLLOW)
work = Path(tempfile.mkdtemp(prefix='.cfw_disk.B38-', dir=VM))
args = SimpleNamespace(vm=VM, work=work, fd=fd, owner_pid=os.getpid(), retain_staged=True, exit_code=1)
base = None; mounted = False; mnt = None
record = {'at':time.time(), 'vm':str(VM), 'changes':[], 'previous_disk_retained':True, 'new_snapshot_flip':False}
try:
    assert txn.stage(args) == 0
    space()
    data = command([disk.HDIUTIL, 'attach', '-nomount', '-plist', '-imagekey', 'diskimage-class=CRawDiskImage', str(work / 'Disk.img')])
    entities = plistlib.loads(data)['system-entities']
    bases = {e['dev-entry'] for e in entities if e.get('content-hint') in ('GUID_partition_scheme', 'FDisk_partition_scheme', 'Apple_partition_scheme')}
    assert len(bases) == 1, bases
    base = bases.pop()
    device = disk.system_volume(base)
    mnt = Path(tempfile.mkdtemp(prefix='.cfw_mount.B38-', dir=VM))
    disk.mount_volume(device, mnt); mounted = True
    unchanged = ['usr/bin/vphoned', 'System/Library/LaunchDaemons/vphoned.plist', 'b', 'sbin/launchd']
    before = {name:sha(mnt / name) for name in unchanged}
    launchd = mnt / 'System/Library/xpc/launchd.plist'
    original_job = plistlib.loads(launchd.read_bytes())
    key = '/System/Library/LaunchDaemons/vphoned-api.plist'
    assert key not in original_job.get('LaunchDaemons', {})
    env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1', VPHONE_PYTHON='/Users/kolar/github/vphone-cli/.venv/bin/python3')
    subprocess.run(['/bin/zsh','-c','set -euo pipefail; SCRIPT_DIR="$1/scripts"; VM_DIR="$2"; MNT1="$3"; source "$SCRIPT_DIR/lib/cfw_common.sh"; cfw_stage_api "$4"','deploy',str(CODE),str(VM),str(mnt),str(GUEST)], env=env, check=True, timeout=30)
    merged = dict(original_job)
    merged['LaunchDaemons'] = dict(original_job.get('LaunchDaemons', {}), **{key:job})
    launchd.write_bytes(plistlib.dumps(merged, sort_keys=False)); launchd.chmod(0o644)
    assert sha(mnt / 'usr/libexec/vphoned-api') == expected['api_sha256']
    assert plistlib.loads((mnt / 'System/Library/LaunchDaemons/vphoned-api.plist').read_bytes()) == job
    assert plistlib.loads(launchd.read_bytes()) == merged
    after = {name:sha(mnt / name) for name in unchanged}
    assert before == after
    record.update(classic_and_environment_before=before, classic_and_environment_after=after, api_sha256=expected['api_sha256'], launchd_previous_entries=len(original_job['LaunchDaemons']), launchd_new_entries=len(merged['LaunchDaemons']), changes=['usr/libexec/vphoned-api','System/Library/LaunchDaemons/vphoned-api.plist','System/Library/xpc/launchd.plist'])
    disk.unmount(mnt); mounted = False
    disk.detach(base); base = None
    space()
    assert txn.publish(args) == 0
    args.exit_code = 0
    record['published'] = True
except BaseException as exc:
    record['failure'] = {'type':type(exc).__name__, 'message':str(exc)}
    raise
finally:
    if mounted: disk.unmount(mnt)
    if base: disk.detach(base)
    try:
        record['finish_exit'] = txn.finish(args)
        record['transaction_directory'] = str(args.work)
    finally:
        os.close(fd); os.close(lock)
        record['free_bytes'] = space()
        path = HERE / 'deployment.json'
        path.write_text(json.dumps(record, indent=2)+'\n'); os.chown(path, uid, gid)
