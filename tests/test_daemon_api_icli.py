"""Host-side checks of the IcliKit archive readers that the API daemon candidate links.

T08 (IcliKit 0.7.5/0.7.6): IPA and deb entry names are read with a thread-local
UTF-8 LC_CTYPE while the caller stays in the C locale, and Mac metadata
(`__MACOSX/`, `._name`) is skipped during IPA extraction. The checks compile the
resolved checkout's own Archive.m/Deb.m and its Tests/ArchiveLocale harness
against the macOS slice of the resolved libarchive. They need the package
checkout left by `make daemon_api_build`; iOS launchd, installd and container
registration are not exercised.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / '.build/daemon-api-v2/Xcode/SourcePackages'
ICLI = PACKAGES / 'checkouts/icli'
LIBARCHIVE = (PACKAGES / 'artifacts/libarchive.xcframework/libarchive/libarchive.xcframework'
              / 'macos-arm64_x86_64/libarchive.framework')
LOCK = ROOT / 'sources/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def pinned_revision():
    pins = json.loads(LOCK.read_text())['pins']
    return next(pin['state']['revision'] for pin in pins if pin['identity'] == 'icli')


def checkout_state():
    if sys.platform != 'darwin' or not shutil.which('xcrun'):
        return 'macOS xcrun required'
    if not (ICLI / 'Tests/ArchiveLocale/main.swift').is_file() or not LIBARCHIVE.is_dir():
        return 'resolved IcliKit checkout missing; run make daemon_api_build'
    revision = subprocess.run(['/usr/bin/git', '-C', str(ICLI), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True).stdout.strip()
    if revision != pinned_revision():
        return f'IcliKit checkout {revision[:12]} is not the pinned revision; rerun make daemon_api_build'
    return None


SKIP = checkout_state()


@unittest.skipIf(SKIP, SKIP or '')
class DaemonAPIIcliArchiveTests(unittest.TestCase):
    def test_utf8_names_and_mac_metadata_in_c_locale(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            include = work / 'include/libarchive'
            include.mkdir(parents=True)
            for header in ('archive.h', 'archive_entry.h'):
                shutil.copy(LIBARCHIVE / 'Headers' / header, include / header)

            # A deb whose data member is PAX with a UTF-8 path, as dpkg-deb builds it.
            deb = work / 'deb'
            share = deb / 'data/var/jb/usr/share/icli-locale-test'
            share.mkdir(parents=True)
            (deb / 'control').mkdir()
            (deb / 'control/control').write_text(
                'Package: dev.owngoal.icli.localetest\nVersion: 1.0\nArchitecture: iphoneos-arm64\n')
            (share / 'What’s New 中文.txt').write_text('unicode deb\n')
            (deb / 'debian-binary').write_text('2.0\n')
            utf8 = dict(os.environ, LC_ALL='en_US.UTF-8')
            subprocess.run(['bsdtar', '--format', 'pax', '-czf', '../control.tar.gz', './control'],
                           cwd=deb / 'control', env=utf8, check=True)
            subprocess.run(['bsdtar', '--format', 'pax', '-czf', '../data.tar.gz', './var'],
                           cwd=deb / 'data', env=utf8, check=True)
            subprocess.run(['ar', '-rcS', 'test.deb', 'debian-binary', 'control.tar.gz', 'data.tar.gz'],
                           cwd=deb, check=True, capture_output=True)

            objects = []
            for source in ('Archive', 'Deb'):
                output = work / f'{source}.o'
                subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', f'-I{work / "include"}',
                                f'-I{ICLI / "Sources/IcliPrivate/include"}',
                                f'-I{ICLI / "Sources/IcliSystemPrivate/include"}',
                                '-c', str(ICLI / f'Sources/IcliPrivate/{source}.m'), '-o', str(output)],
                               check=True, capture_output=True)
                objects.append(str(output))
            harness = work / 'archive-locale-tests'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(work / 'modules'),
                            '-import-objc-header', str(ICLI / 'Tests/ArchiveLocale/Bridge.h'),
                            str(ICLI / 'Tests/ArchiveLocale/main.swift'), *objects,
                            str(LIBARCHIVE / 'Versions/A/libarchive'), '-framework', 'Foundation',
                            '-lz', '-lbz2', '-liconv', '-lxml2', '-o', str(harness)],
                           check=True, capture_output=True)
            # The harness forces setlocale(LC_ALL, "C") and requires US-ASCII before reading.
            result = subprocess.run([str(harness), str(deb / 'test.deb')], capture_output=True, text=True,
                                    env=dict(os.environ, LC_ALL='C'), timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Unicode IPA and deb names in the C locale', result.stdout)
            self.assertIn('Mac metadata skipped', result.stdout)


if __name__ == '__main__':
    unittest.main()
