"""Exercise cache publication and installer wiring with external command doubles."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/cache_systemos.py"
DMG = b"DMG!" + bytes(4092)


class SystemOSCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vphone a2 ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.source = self.base / "SystemOS.dmg.aea"
        self.cache = self.base / "CryptexSystemOS.dmg"
        self.log = self.base / "calls"
        stub = self.bin / "stub"
        stub.write_text(f"#!{sys.executable}\n" + r'''
import json, os, pathlib, plistlib, shutil, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['A2_CALLS'], 'a') as f:
    f.write(json.dumps([name] + args) + '\n')
if name == 'hdiutil':
    if args[0] != 'imageinfo':
        sys.exit(71)  # Never attach a real disk during installer integration tests.
    if args[-1].endswith('.aea'): sys.exit(1)  # hdiutil dispatches by extension.
    data = pathlib.Path(args[-1]).read_bytes()
    known = data.startswith(b'DMG!')
    plistlib.dump({'Properties': {'Encrypted': False},
        'Size Information': {'Total Bytes': len(data)},
        'partitions': {'block-size': 512, 'partitions': [{
            'partition-hint': 'Apple_APFS' if known or data.startswith(b'PART') else 'unknown',
            'partition-filesystems': {'APFS': 'test'} if known else {},
            'partition-start': 0, 'partition-length': 8}]}}, sys.stdout.buffer)
elif name == 'ipsw':
    if os.environ.get('A2_FAIL') == 'key': sys.exit(29)
    print('test-key-do-not-log')
elif name in ('aea', 'cp'):
    if name == 'aea':
        target = pathlib.Path(args[args.index('-o') + 1])
        data = b'DMG!' + bytes(4092)
    else:
        target = pathlib.Path(args[-1])
        data = pathlib.Path(args[-2]).read_bytes()
    target.write_bytes(data[:32] if os.environ.get('A2_FAIL') == name else data)
    if os.environ.get('A2_PAUSE') == name:
        pathlib.Path(os.environ['A2_READY']).touch()
        time.sleep(30)
    if os.environ.get('A2_FAIL') == name: sys.exit(31)
    if os.environ.get('A2_FAIL') == 'invalid-output': target.write_bytes(b'bad!')
elif name == 'sudo':
    if args[0] == '-n': sys.exit(1)
    os.execvp(args[0], args)
elif name == 'python-stub':
    if args and args[0].endswith('cfw.py'):
        print('SystemOS.dmg.aea\nAppOS.dmg')
    elif args and args[0] in ('-c', '--version'): pass
    else: os.execv(sys.executable, [sys.executable] + args)
''')
        stub.chmod(0o755)
        for name in ("ipsw", "aea", "cp", "hdiutil", "sudo", "ldid", "tar", "gtar", "python-stub"):
            (self.bin / name).symlink_to(stub)
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                        A2_CALLS=str(self.log))

    def run_cache(self, **env):
        return subprocess.run([sys.executable, str(HELPER), str(self.source), str(self.cache)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def calls(self, name):
        import json
        return [row for line in self.log.read_text().splitlines()
                if (row := json.loads(line))[0] == name] if self.log.exists() else []

    def test_decrypts_aea_once_and_reuses_valid_cache(self):
        self.source.write_bytes(b"AEA1encrypted")
        first = self.run_cache()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.cache.read_bytes(), DMG)
        self.assertNotIn("test-key-do-not-log", first.stdout + first.stderr)
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(len(self.calls("aea")), 1)
        self.assertEqual(len(self.calls("ipsw")), 1)
        self.assertEqual(len(self.calls("cp")), 0)

    def test_copies_decrypted_aea_filename_once(self):
        self.source.write_bytes(DMG)
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.cache.read_bytes(), DMG)
        self.assertEqual(len(self.calls("cp")), 1)
        self.assertEqual(len(self.calls("aea")), 0)

    def test_rejects_missing_empty_invalid_and_truncated_inputs(self):
        for data in (None, b"", b"AEA", b"bad!" * 1024, b"PART" + bytes(4092), DMG[:512]):
            with self.subTest(data=None if data is None else len(data)):
                self.cache.unlink(missing_ok=True)
                if data is not None: self.source.write_bytes(data)
                result = self.run_cache()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.cache.exists())
        self.assertEqual(len(self.calls("aea")), 0)

    def test_failures_never_publish_partial_output_and_retry_succeeds(self):
        for failure in ("key", "aea", "cp", "invalid-output"):
            with self.subTest(failure=failure):
                self.cache.unlink(missing_ok=True)
                self.source.write_bytes(DMG if failure == "cp" else b"AEA1encrypted")
                result = self.run_cache(A2_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.cache.exists())
                self.assertEqual(list(self.base.glob(".systemos-*")), [])
                self.assertEqual(self.run_cache().returncode, 0)
                self.assertEqual(self.cache.read_bytes(), DMG)

    def test_incomplete_cache_is_rebuilt(self):
        self.source.write_bytes(DMG)
        self.cache.write_bytes(DMG[:512])
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.cache.read_bytes(), DMG)
        self.assertEqual(len(self.calls("cp")), 1)

    def test_interrupted_copy_never_publishes_cache_and_cleans_staging(self):
        import time
        self.source.write_bytes(DMG)
        ready = self.base / "ready"
        process = subprocess.Popen(
            [sys.executable, str(HELPER), str(self.source), str(self.cache)],
            env=dict(self.env, A2_PAUSE="cp", A2_READY=str(ready)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            self.assertFalse(self.cache.exists())
            process.terminate()
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(self.cache.exists())
            self.assertEqual(list(self.base.glob(".systemos-*")), [])
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_cache_symlink_is_rejected_without_changing_its_target(self):
        self.source.write_bytes(DMG)
        target = self.base / "other.dmg"
        target.write_bytes(b"unrelated file")
        self.cache.symlink_to(target)
        self.assertNotEqual(self.run_cache().returncode, 0)
        self.assertEqual(target.read_bytes(), b"unrelated file")

    def test_valid_modified_cache_is_preserved_without_source(self):
        modified = DMG[:100] + b"EXP" + DMG[103:]
        self.cache.write_bytes(modified)
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.cache.read_bytes(), modified)
        self.assertEqual(len(self.calls("cp")), 0)

    def test_all_installers_use_the_cache_before_attempting_attachment(self):
        # Run unmodified installer files in a disposable tree. Absolute mount
        # commands are shell functions; hdiutil attach is a failing double.
        scripts = self.base / "scripts"
        scripts.mkdir()
        for name in ("cfw_install.sh", "cfw_install_dev.sh", "cfw_install_jb.sh", "cfw_install_exp.sh", "cache_systemos.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        overlay = scripts / "resources/cfw_dev"
        overlay.mkdir(parents=True)
        (overlay / "rpcserver_ios").write_bytes(b"overlay")
        zdot = self.base / "zdot"
        zdot.mkdir()
        (zdot / ".zshenv").write_text('''
export PATH="$_VPHONE_PATH"
function /sbin/mount() { print "stub on $CFW_HOST_MNT/mnt1 "; }
function /sbin/mount_apfs() { return 99; }
function mount() { return 0; }
''')
        for variant in ("", "_dev", "_jb", "_exp"):
            for encrypted in (False, True):
                with self.subTest(variant=variant, encrypted=encrypted):
                    vm = self.base / f"vm{variant}{encrypted}"
                    restore = vm / "iPhone_Test_Restore"
                    restore.mkdir(parents=True)
                    (restore / "BuildManifest.plist").touch()
                    (restore / "SystemOS.dmg.aea").write_bytes(b"AEA1encrypted" if encrypted else DMG)
                    (restore / "AppOS.dmg").write_bytes(DMG)
                    (vm / "cfw_input").mkdir()
                    (vm / ".iosbinpack_tmp/iosbinpack64/usr/local/bin").mkdir(parents=True)
                    env = dict(self.env, ZDOTDIR=str(zdot), _VPHONE_PATH=self.env["PATH"],
                               VPHONE_PYTHON=str(self.bin / "python-stub"),
                               CFW_HOST_CONTAINER="test-only", CFW_HOST_MNT=str(vm / "mounts"))
                    result = subprocess.run(["/bin/zsh", str(scripts / f"cfw_install{variant}.sh"), str(vm)],
                                            env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)  # stopped by the attach double
                    cache = vm / ".cfw_temp/CryptexSystemOS.dmg"
                    self.assertTrue(cache.is_file(), result.stdout + result.stderr)
                    self.assertEqual(cache.read_bytes(), DMG)


if __name__ == "__main__":
    unittest.main()
