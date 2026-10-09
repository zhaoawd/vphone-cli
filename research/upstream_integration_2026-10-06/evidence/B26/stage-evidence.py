from pathlib import Path
import hashlib
import json
import shutil

scratch = Path('/private/tmp/vphone-b26')
destination = scratch / 'archive'
destination.mkdir(exist_ok=True)

def copy_tree(source, target):
    source, target = Path(source), destination / target
    assert source.is_dir(), source
    shutil.copytree(source, target, dirs_exist_ok=True)
    for original in source.rglob('*'):
        if original.is_file():
            copied = target / original.relative_to(source)
            assert original.read_bytes() == copied.read_bytes(), copied

copy_tree('/private/tmp/vphone-b26-t24', 'T24')
copy_tree('/private/tmp/vphone-b26-t40', 'T40-readonly')
copy_tree(scratch / 'vm-new', 'T08-vm-new')
shutil.copy2(scratch / 'previous-host-help.json', destination / 'T08-vm-new/previous-host-help.json')
for mode in ['normal', 'escaped']:
    source = Path('/private/tmp/vphone-b25-t46') / ('ui-final-' + mode)
    copy_tree(source, 'T46-UI/' + mode)
    result = json.loads((source / 'result.json').read_text())
    assert result['exact_expected'] and not result['writer_alive'] and not result['matching_processes']
    assert result['artifact']['source_build_head'] == '53580180f09819ec539ba656c15fab7a23fdc1c3'
    assert result['artifact']['main_identical_after_signature_removal']
    data = Path(result['log']).read_bytes()
    assert len(data) == result['bytes'] == 138939
    assert hashlib.sha256(data).hexdigest() == result['sha256']
    assert len(data.splitlines()) == result['lines'] == 10002
    (destination / 'T46-UI' / mode / 'command.log').write_bytes(data)
for name in ['prepare-final-ui.py', 'verify-final-ui.py']:
    shutil.copy2(Path('/private/tmp/vphone-b25') / name, destination / 'T46-UI' / name)
(destination / '.gitattributes').write_text('* -text\n')
files = [{'path': str(path.relative_to(destination)), 'bytes': path.stat().st_size,
          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
         for path in sorted(destination.rglob('*')) if path.is_file()]
(scratch / 'stage-manifest.json').write_text(json.dumps(files, indent=2) + '\n')
print(json.dumps({'files': len(files), 'bytes': sum(f['bytes'] for f in files)}))
