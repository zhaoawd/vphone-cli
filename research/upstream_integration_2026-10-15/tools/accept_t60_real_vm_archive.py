"""T60 archive acceptance on a stopped source's APFS clone. Never boots a VM.

Prepare with a verified CLI, then import with the selected verified candidate.
All output must be new and inside this repository's .build directory.
"""
import argparse
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def files(vm):
    names = ['Disk.img', 'config.plist', 'SEPStorage', 'nvram.bin',
             'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin', 'udid-prediction.txt']
    names += sorted(p.name for p in vm.glob('*.shsh'))
    return {name: digest(vm / name) for name in names if (vm / name).is_file()}


def payload_size(vm, *, logical=False):
    # Match this acceptance fixture's default export policy, count hardlinks once,
    # and include auxiliary payloads rather than only Disk.img. Import capacity
    # uses the logical upper bound: observed large-VM allocation exceeded the
    # source's allocated size even though the restored content was identical.
    patterns = ['*.vphoned.signed', '*cfw_input*', '*cfw_jb_input*', '*.cfw_temp*',
                '*.cfw_mount.*', '*.cfw_disk.*', '*.cfw-history*',
                '*.vphone-runtime.json', 'vphone.sock', '*_Restore*']
    seen = set()
    total = 0
    for folder, directories, names in os.walk(vm, followlinks=False):
        def included(name):
            relative = str((Path(folder) / name).relative_to(vm))
            return not any(fnmatch.fnmatchcase(relative, p) or fnmatch.fnmatchcase(name, p) for p in patterns)
        directories[:] = [name for name in directories if included(name)]
        for name in names:
            if not included(name):
                continue
            info = (Path(folder) / name).lstat()
            key = (info.st_dev, info.st_ino)
            if stat.S_ISREG(info.st_mode) and key not in seen:
                seen.add(key)
                total += info.st_size if logical else info.st_blocks * 512
    return total


def run(command, log, volume, archive_parent=None):
    with log.open('w') as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        interrupted = None
        started = time.monotonic()
        deadline = started + 1800
        next_sample = started
        metrics = log.with_suffix('.metrics.jsonl')
        while process.poll() is None:
            available = shutil.disk_usage(volume).free
            now = time.monotonic()
            if now >= next_sample:
                disks = {str(p.relative_to(volume)): dict(logicalBytes=p.stat().st_size, allocatedBytes=p.stat().st_blocks * 512)
                         for p in volume.glob('import-*/.import-*/contents/*/Disk.img')}
                with metrics.open('a') as samples:
                    samples.write(json.dumps(dict(elapsedSeconds=now-started, freeBytes=available, disks=disks)) + '\n')
                next_sample = now + 1
            oversized = archive_parent and sum(p.stat().st_size for p in archive_parent.rglob('*') if p.is_file()) > 32 << 30
            if interrupted is None and (available < 4 << 30 or oversized or time.monotonic() > deadline):
                interrupted = 'space/archive size/time bound'
                process.send_signal(signal.SIGINT)
            time.sleep(0.2)
        if process.returncode or interrupted:
            raise RuntimeError(f'{interrupted or "CLI failure"}: exit {process.returncode}; see {log}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'import'])
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--backend', choices=['native', 'system-tar'], default='native')
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    work = args.work.resolve()
    cli = args.cli.resolve(strict=True)
    assert source.parent == ROOT and source.name == 'vm-new', 'only the selected stopped legacy VM is in scope'
    assert work.is_relative_to(ROOT / '.build') and work != ROOT / '.build'
    assert cli.is_relative_to(ROOT / '.build')
    if args.phase == 'prepare':
        assert not work.exists(), 'fresh output directory required'
        assert shutil.disk_usage(ROOT).free >= min((source / 'Disk.img').stat().st_blocks * 512, 32 << 30) + (4 << 30), 'insufficient export capacity'
        work.mkdir()
        fd = os.open(source, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
            assert not any(Path(row.get('image-path', '')).resolve() == source / 'Disk.img' for row in images.get('images', [])), 'source attached'
            original = files(source)
            source_info = (source / 'Disk.img').stat()
            library = work / 'clone-library'; library.mkdir()
            clone = library / source.name
            subprocess.run(['/bin/cp', '-cR', str(source), str(clone)], check=True)
            assert files(clone) == original, 'clone content differs'
            assert (clone / 'Disk.img').stat().st_ino != source_info.st_ino
            assert files(source) == original
        finally:
            os.close(fd)
        archives = work / 'archives'; archives.mkdir()
        archive = archives / 'legacy.tzst'
        run([str(cli), 'vm', 'export', source.name, '--library-root', str(library),
             '--out', str(archive), '--archive-backend', args.backend], work / 'export.log', work, archives)
        assert files(clone) == original
        record = dict(state='exported', source=str(source), sourceFiles=original,
                      archiveSHA256=digest(archive), archiveBytes=archive.stat().st_size,
                      exporterSHA256=digest(cli), exporterBackend=args.backend)
        (work / 'prepared.json').write_text(json.dumps(record, indent=2) + '\n')
    else:
        record = json.loads((work / 'prepared.json').read_text())
        archive = work / 'archives/legacy.tzst'
        assert digest(archive) == record['archiveSHA256']
        required = payload_size(work / 'clone-library' / source.name, logical=True) + (4 << 30)
        assert shutil.disk_usage(work).free >= required, f'import requires {required} free bytes including 4GiB reserve'
        destination = work / ('import-' + args.backend)
        assert not destination.exists(), 'fresh destination required'
        destination.mkdir()
        run([str(cli), 'vm', 'import', str(archive), '--library-root', str(destination),
             '--name', 'restored', '--archive-backend', args.backend], work / ('import-' + args.backend + '.log'), work)
        assert files(destination / 'restored') == record['sourceFiles'], 'restored bytes differ'
        assert digest(archive) == record['archiveSHA256']
        fd = os.open(source, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert files(source) == record['sourceFiles'], 'original source changed'
        finally:
            os.close(fd)
        assert not any(p.name.startswith('.import-') for p in destination.iterdir())
        record.update(state='passed', importerSHA256=digest(cli), importerBackend=args.backend,
                      restoredFiles=files(destination / 'restored'), sourceUnchanged=True, bootValidated=False)
        (work / ('result-' + args.backend + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
