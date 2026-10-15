"""Task8 fixed-V4-driver cleanup: same-daemon SIGCONT only; no debugger API."""
import ctypes
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import struct
import sys
import time
from urllib.parse import unquote

E = Path(__file__).resolve().parent
DRIVER = E / 'scoped-amfi-v4-once.py'
DRIVER_SHA256 = 'f99f3c92d6ef68d3cf0f18d295622603ed72991950da9c39fdecd8a0da37c219'
RUNTIME = Path('/Users/qcz3840/Library/Python/3.9/lib/python/site-packages/amfidont/bypass_runtime.py')
RUNTIME_SHA256 = 'bd418fcb2732c08162a115b8537fa4cde8cbb4212bc2361e9113decf8325bab0'
BINARY = '/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm'
BINARY_SHA256 = '0e5944b2b79aaa059af156cb47824c399183d970a93db35b839b5dda39b31ca1'
CDHASH = '43c00d51b4c7f07a5feba006f3c244edbac39cea'
VM = '/private/tmp/vphone-task8-acceptance-vms/task8-copy'
AMFID = '/usr/libexec/amfid'
PREFIX = 'TASK8_V4_ONCE_'
SRUN, SSTOP, PROC_FLAG_TRACED = 2, 4, 2
LABEL = re.compile(r'[a-z0-9]+(?:-[a-z0-9]+)*\Z')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def valid_label(label):
    require(isinstance(label, str) and len(label) <= 80 and LABEL.fullmatch(label), 'Invalid evidence label')


def json_object(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key: ' + key)
            result[key] = value
        return result
    def bad_constant(value):
        raise RuntimeError('Invalid JSON constant: ' + value)
    value = json.loads(data, object_pairs_hook=pairs, parse_constant=bad_constant)
    require(isinstance(value, dict), 'Expected JSON object')
    return value


@dataclass(frozen=True)
class Blob:
    data: bytes
    birth_ns: int
    identity: tuple
    sha256: str


# attrlist uses five attribute bitmap groups; returned attributes are 4-byte aligned.
class AttrList(ctypes.Structure):
    _fields_ = [('bitmapcount', ctypes.c_uint16), ('reserved', ctypes.c_uint16),
                ('commonattr', ctypes.c_uint32), ('volattr', ctypes.c_uint32),
                ('dirattr', ctypes.c_uint32), ('fileattr', ctypes.c_uint32), ('forkattr', ctypes.c_uint32)]


def file_birth_ns(fd):
    """Exact file creation timespec, without Python's floating birthtime."""
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    function = libc.fgetattrlist
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
    function.restype = ctypes.c_int
    attrs = AttrList(5, 0, 0x200, 0, 0, 0, 0)  # ATTR_CMN_CRTIME
    buffer = ctypes.create_string_buffer(32)
    require(function(fd, ctypes.byref(attrs), buffer, len(buffer), 0) == 0, 'Cannot read exact file birthtime')
    length = struct.unpack_from('=I', buffer.raw, 0)[0]
    require(length == 20, 'Unexpected creation-time attribute size')
    seconds, nanoseconds = struct.unpack_from('=qq', buffer.raw, 4)
    require(seconds > 0 and 0 <= nanoseconds < 1_000_000_000, 'Invalid file birthtime')
    return seconds * 1_000_000_000 + nanoseconds


def strict_blob(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 < before.st_size <= 16 << 20,
                'Evidence must be one bounded ordinary file: ' + str(path))
        birth = file_birth_ns(fd)
        chunks, count = [], 0
        while True:
            chunk = os.read(fd, min(1 << 20, (16 << 20) + 1 - count))
            if not chunk:
                break
            chunks.append(chunk); count += len(chunk)
            require(count <= 16 << 20, 'Evidence grew past limit')
        after, named = os.fstat(fd), os.lstat(path)
        keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')
        require(count == before.st_size and all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in keys)
                and file_birth_ns(fd) == birth, 'Evidence changed during read: ' + str(path))
        data = b''.join(chunks)
        return Blob(data, birth, tuple(getattr(after, k) for k in keys), hashlib.sha256(data).hexdigest())
    finally:
        os.close(fd)


class ProcBSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'bsd_state', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_seconds', ctypes.c_uint64), ('start_microseconds', ctypes.c_uint64)]


class NativeOperations:
    """The only process mutation in this adapter is send_continue(pid)."""
    def euid(self):
        return os.geteuid()

    def read(self, path):
        return strict_blob(path)

    def observe(self, pid):
        require(sys.platform == 'darwin' and ctypes.sizeof(ProcBSDInfo) == 136, 'Unsupported native process ABI')
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        info = lib.proc_pidinfo
        info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        info.restype = ctypes.c_int
        path = lib.proc_pidpath
        path.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]; path.restype = ctypes.c_int
        first, second = ProcBSDInfo(), ProcBSDInfo()
        require(info(pid, 3, 0, ctypes.byref(first), 136) == 136, 'Native process info unavailable')
        buffer = ctypes.create_string_buffer(4096)
        count = path(pid, buffer, len(buffer))
        require(0 < count < len(buffer), 'Native process path unavailable')
        require(info(pid, 3, 0, ctypes.byref(second), 136) == 136, 'Native process disappeared')
        names = ('pid', 'ppid', 'uid', 'start_seconds', 'start_microseconds')
        require(all(getattr(first, k) == getattr(second, k) for k in names), 'Native process identity changed during observation')
        require(not (first.flags & PROC_FLAG_TRACED or second.flags & PROC_FLAG_TRACED), 'Daemon is traced')
        result = {k: int(getattr(second, k)) for k in ('flags', 'bsd_state', 'xstatus') + names}
        result['path'] = buffer.value.decode('utf-8', errors='strict')
        return result

    def send_continue(self, pid):
        os.kill(pid, signal.SIGCONT)

    def wait(self):
        time.sleep(0.05)


def qualify_evidence(label, operations):
    paths = [DRIVER, RUNTIME, E / (label + '-amfi-once.json'), E / (label + '-amfi-once.log')]
    blobs = {path: operations.read(path) for path in paths}
    require(blobs[DRIVER].sha256 == DRIVER_SHA256, 'Fixed F99 driver hash differs')
    require(blobs[RUNTIME].sha256 == RUNTIME_SHA256, 'Fixed runtime hash differs')
    result = json_object(blobs[paths[2]].data)
    require(type(result.get('exit_code')) is int and result['exit_code'] == 0, 'Fixed driver did not exit zero')
    require(result.get('command') in (
        ['sudo', '-n', '/usr/bin/python3', str(DRIVER), '--run'],
        ['/usr/bin/sudo', '-n', '/usr/bin/python3', str(DRIVER), '--run']), 'Unexpected fixed-driver invocation')
    require(result.get('log') == paths[3].name, 'Driver result/log association differs')
    elapsed = result.get('elapsed_seconds')
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0, 'Invalid driver result duration')
    events = []
    lines = blobs[paths[3]].data.decode('utf-8', errors='strict').splitlines()
    for line in lines:
        if line.startswith(PREFIX):
            event, separator, value = line[len(PREFIX):].partition(' ')
            require(separator, 'Malformed driver event')
            events.append((event, json_object(value)))
    require(len(events) >= 9, 'Incomplete fixed-driver event log')
    kinds = [event for event, _ in events]
    require(kinds[:2] == ['SCOPE', 'READY'] and kinds[-5:] == [
        'COMPLETE', 'EXIT_STATE', 'DELETE_BREAKPOINTS', 'DETACH', 'CLEANUP_DONE'], 'Driver event ordering differs')
    require(all(kind == 'HOOK' for kind in kinds[2:-5]), 'Unknown or duplicate driver events')
    require(lines and lines[-1] == PREFIX + 'CLEANUP_DONE {}', 'Driver cleanup is not the final log record')
    scope = events[0][1]
    expected = {'binary': BINARY, 'sha256': BINARY_SHA256, 'cdhashes': [CDHASH], 'paths': [],
                'allow_all': False, 'spoof_apple': True, 'persistent_config': False, 'permitted_vm': VM,
                'cleanup': 'both authorized hooks -> delete breakpoints -> detach(false); no Stop request'}
    require(set(scope) == set(expected) | {'driver_pid'} and all(scope.get(k) == v and type(scope.get(k)) is type(v) for k, v in expected.items()), 'Fixed V4 scope differs')
    require(type(scope['driver_pid']) is int and scope['driver_pid'] > 0, 'Invalid driver PID')
    ready = events[1][1]
    require(set(ready) == {'amfid_pid'} and type(ready['amfid_pid']) is int and 0 < ready['amfid_pid'] <= 2_147_483_647, 'Expected one strict READY PID')
    matched = []
    for _, hook in events[2:-5]:
        require(hook.get('hook') in ('validate', 'isApple') and hook.get('stopped') is True, 'Invalid hook record')
        if hook.get('cdhash') == CDHASH:
            require(type(hook.get('return_value')) is int and hook['return_value'] == 1
                    and isinstance(hook.get('path'), str) and unquote(hook['path']) == BINARY, 'Matched hook result/path differs')
            matched.append(hook['hook'])
        else:
            require('return_value' not in hook, 'Nonmatching hook reports a patched return')
    require(sorted(matched) == ['isApple', 'validate'], 'Expected exactly two matched V4 hooks')
    require(events[-5][1] == {'matched_hooks': ['isApple', 'validate']}, 'Matched-hook completion differs')
    require(events[-4][1] == {'state': 5, 'status': -1, 'description': None}, 'Cleanup did not use the existing stopped hook state')
    require(events[-3][1] == {'success': True} and events[-3][1]['success'] is True, 'Breakpoint deletion failed')
    detach = events[-2][1]
    require(set(detach) == {'success', 'error', 'keep_stopped'} and detach['success'] is True
            and detach['keep_stopped'] is False and detach['error'] == 'success', 'Detach(false) failed')
    require(events[-1][1] == {}, 'Unexpected cleanup completion fields')
    return ready['amfid_pid'], blobs[paths[3]].birth_ns, blobs


def identity(observation):
    return tuple(observation[k] for k in ('pid', 'ppid', 'uid', 'path', 'start_seconds', 'start_microseconds'))


def qualify_process(observation, pid, log_birth_ns):
    keys = ('flags', 'bsd_state', 'xstatus', 'pid', 'ppid', 'uid', 'start_seconds', 'start_microseconds')
    require(all(type(observation.get(k)) is int for k in keys), 'Incomplete native process observation')
    require(observation['pid'] == pid and observation['ppid'] == 1 and observation['uid'] == 0
            and observation.get('path') == AMFID, 'Daemon PID/path/uid/parent association differs')
    require(not observation['flags'] & PROC_FLAG_TRACED, 'Daemon is traced')
    require(observation['start_seconds'] > 0 and 0 <= observation['start_microseconds'] < 1_000_000,
            'Invalid daemon start time')
    start_ns = observation['start_seconds'] * 1_000_000_000 + observation['start_microseconds'] * 1000
    require(start_ns <= log_birth_ns, 'Daemon started after driver log birth; PID reuse refused')
    require(observation['bsd_state'] == SRUN or
            observation['bsd_state'] == SSTOP and observation['xstatus'] == int(signal.SIGSTOP), 'Unsupported daemon state')


def restore(label, operations):
    record = {'passed': False, 'label': label, 'signals_attempted': [], 'signals_sent': [],
              'scope': 'Fixed F99 driver/V4 CDHash evidence; same native amfid identity; SIGCONT only',
              'limitation': 'Detach(false) is not proof of BSD resume; cause of the observed stopped state remains unknown'}
    try:
        valid_label(label)
        require(operations.euid() == 0, 'Live cleanup requires root')
        pid, birth, blobs = qualify_evidence(label, operations)
        record.update(pid=pid, driver_log_birth_ns=birth,
                      evidence={str(p): {'sha256': b.sha256, 'identity': b.identity, 'birth_ns': b.birth_ns} for p, b in blobs.items()})
        before = operations.observe(pid); record['before'] = before
        qualify_process(before, pid, birth)
        # Complete every source/evidence recheck before the final native identity
        # observation; no artifact rewrite or callback is authorized in between.
        for path, original in blobs.items():
            require(operations.read(path) == original, 'Qualification evidence changed before action')
        final = operations.observe(pid); record['immediately_before_action'] = final
        qualify_process(final, pid, birth)
        require(identity(final) == identity(before) and final['bsd_state'] == before['bsd_state'], 'Daemon identity/state changed before action')
        if final['bsd_state'] == SRUN:
            record.update(after=final, action='already-running; no signal', passed=True)
            return record
        event = {'pid': pid, 'signal': 'SIGCONT'}
        record['signals_attempted'].append(event)
        operations.send_continue(pid)
        record['signals_sent'].append(event)
        for attempt in range(20):
            after = operations.observe(pid); record['after'] = after
            qualify_process(after, pid, birth)
            require(identity(after) == identity(before), 'Daemon identity changed after SIGCONT')
            if after['bsd_state'] == SRUN:
                record.update(action='same-daemon SIGCONT; running readback', passed=True)
                return record
            if attempt < 19:
                operations.wait()
        raise RuntimeError('Same daemon did not read back SRUN after one SIGCONT')
    except BaseException as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
        return record


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    require(len(args) == 1, 'usage: restore-acceptance-amfid.py <label>')
    label = args[0]; valid_label(label)
    destination = E / (label + '-amfi-restore-check.json')
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        result = restore(label, NativeOperations())
        data = (json.dumps(result, indent=2) + '\n').encode()
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
        print(json.dumps(result), flush=True)
        return 0 if result['passed'] else 1
    finally:
        os.close(fd)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try:
        sys.exit(main())
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        sys.exit(1)
