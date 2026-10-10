"""T08 代码、冻结工件及 VM 路径；加载配置不访问客户机磁盘。"""
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path

FLOOR = 5 * 1024**3


@dataclass(frozen=True)
class Workspace:
    code_root: Path
    artifact_root: Path
    vm_root: Path
    work_root: Path
    evidence: Path

    @property
    def research_vm(self):
        return self.vm_root / 'vm-roothide-b33-20261010'

    @property
    def source_vm(self):
        return self.vm_root / 'vm-new'

    @property
    def bundle(self):
        return self.artifact_root / '.build/vphone-cli.app'

    @property
    def vm_binary(self):
        return self.bundle / 'Contents/MacOS/vphone-vm'

    @property
    def candidate(self):
        return self.artifact_root / '.build/daemon-api-v2/candidate'

    @property
    def components(self):
        return self.artifact_root / '.build/guest-components-v2/stage'

    @property
    def packages(self):
        return self.artifact_root / '.build/daemon-api-v2/Xcode/SourcePackages'

    def check_space(self):
        state = os.statvfs(self.code_root)
        available = state.f_bavail * state.f_frsize
        if available < FLOOR:
            raise RuntimeError('STOP: disk below 5 GiB')
        return available


def load_workspace(config):
    config = Path(config).resolve(strict=True)
    raw = json.loads(config.read_text())
    required = {'code_root', 'artifact_root', 'vm_root', 'work_root'}
    if set(raw) != required:
        raise ValueError('Workspace configuration requires four explicit roots')
    roots = {}
    for name in required:
        path = Path(raw[name])
        if not path.is_absolute():
            raise ValueError(f'{name} must be absolute')
        roots[name] = path.resolve()
    code = roots['code_root']
    if not config.is_relative_to(code) or not (code / 'Package.swift').is_file():
        raise ValueError('Configuration must belong to the code checkout')
    work = roots['work_root']
    if not work.is_relative_to(code / '.build'):
        raise ValueError('Work output must remain in the code checkout .build')
    if roots['artifact_root'].is_relative_to(work) or roots['vm_root'].is_relative_to(work):
        raise ValueError('Work output must not contain frozen artifacts or VMs')
    for name in ('artifact_root', 'vm_root'):
        if not roots[name].is_dir():
            raise ValueError(f'{name} does not exist')
    result = Workspace(**roots, evidence=config.parent)
    result.check_space()
    return result


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Expected regular input: {path}')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_entries(root, entries):
    checked = []
    for entry in entries:
        relative = Path(entry['path'])
        path = root / relative
        if relative.is_absolute() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f'Input escapes root: {relative}')
        actual = digest(path)
        if actual != entry['sha256']:
            raise ValueError(f'Input digest mismatch: {relative}')
        checked.append(str(relative))
    return checked


def offline_runtime_entrypoint(script):
    """仅复核运行入口的路径配置；本批次不提供 VM 运行动作。"""
    import argparse
    parser = argparse.ArgumentParser(description='T08 offline runtime-path check')
    parser.add_argument('--workspace', type=Path, default=Path(script).with_name('workspace.json'))
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--check', action='store_true')
    actions.add_argument('--run', action='store_true')
    options = parser.parse_args()
    paths = load_workspace(options.workspace)
    if options.run:
        raise SystemExit('B37 scope is offline only; --run is disabled')
    expected = 'a4f8a4155a95e3d0c9067f856bb09a165df22cc9e55fcf9356f01ab16b0d11f4'
    if digest(paths.vm_binary) != expected:
        raise ValueError('Frozen VM artifact digest mismatch')
    print(json.dumps({'code_root': str(paths.code_root), 'artifact_root': str(paths.artifact_root),
                      'research_vm': str(paths.research_vm), 'source_vm': str(paths.source_vm),
                      'current_run': str(paths.work_root / 'current-run'),
                      'vm_sha256': expected, 'runtime_executed': False}, indent=2))
