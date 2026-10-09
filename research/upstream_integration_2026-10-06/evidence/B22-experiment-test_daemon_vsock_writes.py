import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DaemonVsockWriteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stage = ROOT / '.build/test-daemon-vsock'
        source = cls.stage / 'Sources/Probe'
        source.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / 'tests/fixtures/daemon_vsock/main.swift', source / 'main.swift')
        production = ROOT / 'sources/VPhoneDaemon/Daemon/GuestVsockWriteHandler.swift'
        guarded = production.exists()
        if guarded:
            shutil.copyfile(production, source / production.name)
        else:
            (source / production.name).unlink(missing_ok=True)
        nio = ROOT / '.build/daemon-api-v2/Xcode/SourcePackages/checkouts/swift-nio'
        if not nio.is_dir():
            raise unittest.SkipTest('Pinned NIO checkout absent; prepare with scripts/build_daemon_api.sh')
        settings = '[.define("GUARDED_VSOCK")]' if guarded else '[]'
        (cls.stage / 'Package.swift').write_text('// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name:"Probe", dependencies:[.package(path:"' + str(nio) + '")], targets:[.executableTarget(name:"Probe",dependencies:[.product(name:"NIOCore",package:"swift-nio"),.product(name:"NIOEmbedded",package:"swift-nio"),.product(name:"NIOConcurrencyHelpers",package:"swift-nio")],swiftSettings:' + settings + ')])\n')
        env = {**os.environ, 'SWIFTCI_USE_LOCAL_DEPS': '1'}
        subprocess.run(['swift', 'build', '--package-path', str(cls.stage), '--disable-sandbox', '-j', '4'], env=env, check=True, timeout=180)
        cls.binary = cls.stage / '.build/debug/Probe'

    def test_large_reply_preserves_bytes_and_waits_for_transport(self):
        subprocess.run([str(self.binary), 'drain'], check=True, timeout=10)

    def test_transport_close_fails_pending_reply_without_hanging(self):
        subprocess.run([str(self.binary), 'close'], check=True, timeout=10)
