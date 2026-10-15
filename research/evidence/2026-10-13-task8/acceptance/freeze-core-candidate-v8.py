import datetime
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path('/Users/qcz3840/github/vphone-cli')
BUILD = Path('/private/tmp/vphone-task8-acceptance-build')
E = ROOT / 'research/evidence/2026-10-13-task8/acceptance'

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def source_file_set(base):
    found = {name for name in ['Package.swift', 'Package.resolved', 'Makefile', 'requirements.txt', 'debs.list', 'README.md', '.gitmodules']}
    for directory in ['sources', 'scripts', 'vendor', 'dependencies', 'tools', 'tests']:
        found.update(str(p.relative_to(base)) for p in (base / directory).rglob('*') if p.is_file() and not {'.git', '.build', '__pycache__', '.DS_Store'}.intersection(p.relative_to(base).parts) and p.suffix != '.pyc')
    return found

def check_sources():
    manifest = json.loads((E / 'build-source-v8-manifest.json').read_text())
    changed = [p for p, h in manifest['files_sha256'].items() if not (BUILD / p).is_file() or sha(BUILD / p) != h]
    production_changed = [p for p, h in manifest['production_files_sha256'].items() if not (ROOT / p).is_file() or sha(ROOT / p) != h]
    generated = BUILD / 'sources/vphone-cli/VPhoneBuildInfo.swift'
    commit = subprocess.check_output(['git', '-C', str(BUILD), 'rev-parse', '--short', 'HEAD'], text=True).strip()
    expected = '// Auto-generated — do not edit\nenum VPhoneBuildInfo { static let commitHash = "' + commit + '" }\n'
    assert generated.read_text() == expected
    unexpected = [p for p in changed if p != 'sources/vphone-cli/VPhoneBuildInfo.swift']
    added_build = sorted(source_file_set(BUILD) - set(manifest['files_sha256']))
    added_production = sorted(source_file_set(ROOT) - set(manifest['production_files_sha256']))
    report = {'changed_source_files': changed, 'allowed_generated_changes': ['sources/vphone-cli/VPhoneBuildInfo.swift'], 'unexpected_changes': unexpected, 'production_changed_since_freeze': production_changed, 'new_build_files': added_build, 'new_production_files': added_production, 'generated_info_sha256': sha(generated), 'generated_info_matches_build_commit': True, 'passed': not (unexpected or production_changed or added_build or added_production)}
    (E / 'build-source-v8-postbuild-comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    (E / 'build-source-v8-generated-info.json').write_text(json.dumps({'path': str(generated), 'content': generated.read_text(), 'sha256': sha(generated)}, indent=2) + '\n')
    assert report['passed'], report
    print(json.dumps(report, indent=2))

def check_artifacts():
    old = json.loads((E / 'v1-v7-evidence-preservation-before-v8.json').read_text())
    report = {name: (E / name).is_file() and sha(E / name) == h for name, h in old.items()}
    for version in range(1, 8):
        name = 'core-candidate' + ('' if version == 1 else '-v' + str(version)) + '-manifest.json'
        prior = json.loads((E / name).read_text())
        bundle = Path(prior['bundle'])
        report['v' + str(version) + '_archive'] = sha(Path(prior['archive'])) == prior['archive_sha256']
        report['v' + str(version) + '_bundle_files'] = all((bundle / p).is_file() and sha(bundle / p) == h for p, h in prior['files_sha256'].items())
        report['v' + str(version) + '_bundle_file_set'] = set(prior['files_sha256']) == {str(p.relative_to(bundle)) for p in bundle.rglob('*') if p.is_file()}
    saved = json.loads((E / 'signed-app-v7-preservation-before-v8.json').read_text())
    app = Path(saved['path'])
    report['signed_app_v7_copy_files'] = all((app / p).is_file() and sha(app / p) == h for p, h in saved['files_sha256'].items())
    report['signed_app_v7_copy_file_set'] = set(saved['files_sha256']) == {str(p.relative_to(app)) for p in app.rglob('*') if p.is_file()}
    (E / 'v1-v7-preservation-after-v8.json').write_text(json.dumps(report, indent=2) + '\n')
    assert all(report.values()), [k for k, passed in report.items() if not passed]
    manifest = json.loads((E / 'core-candidate-v8-manifest.json').read_text())
    bundle = Path(manifest['bundle'])
    archive = Path(manifest['archive'])
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == '2.6.20261020' and info['CFBundleVersion'] == '2026101403'
    assert sha(archive) == manifest['archive_sha256']
    with zipfile.ZipFile(archive) as contents:
        checks = {p: hashlib.sha256(contents.read('VPhone.bundle/' + p)).hexdigest() == h for p, h in manifest['files_sha256'].items()}
    assert all(checks.values())
    provenance = json.loads((bundle / 'Contents/Resources/task8-candidate-provenance.json').read_text())
    assert provenance['host_source_manifest_sha256'] == sha(E / 'build-source-v8-manifest.json')
    final = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'version': manifest['version'], 'build_version': info['CFBundleVersion'], 'source_manifest_sha256': sha(E / 'build-source-v8-manifest.json'), 'archive_sha256': sha(archive), 'bundle_file_count': len(checks), 'zip_members_match_manifest': True, 'provenance_matches_source_manifest': True, 'all_prior_evidence_and_artifacts_preserved': True, 'installed': False, 'vm_executed': False, 'amfi_modified': False, 'tcc_modified': False}
    (E / 'core-candidate-v8-final-freeze.json').write_text(json.dumps(final, indent=2) + '\n')
    print(json.dumps(final, indent=2))

check_sources()
if '--sources-only' not in sys.argv:
    check_artifacts()
