"""提取固定目标的声明 ID 差异；不判断补丁效果或迁移等价性。"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
OBJECTS = '/private/tmp/vphone-upstream-proxy-20261006'
PREFIX = 'VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/'
PREVIOUS = 'a969cd5d9206932dc1a2797348027fbc7d0ee347'
TARGET = '2d21d21fbdd4f51f013616273ceda9b35a3e0789'
PRESETS = 'VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/'


def source(ref, path):
    return subprocess.check_output(['git', '--git-dir', OBJECTS, 'show', ref + ':' + path], text=True)


def collect(ref):
    paths = subprocess.check_output(['git', '--git-dir', OBJECTS, 'ls-tree', '-r', '--name-only', ref, '--', PREFIX], text=True).splitlines()
    text = {p: source(ref, p) for p in paths if p.endswith('.swift')}
    constants = {}
    for path, content in text.items():
        for name, value in re.findall(r'static let (\w+)\s*=\s*"([^"]+)"', content):
            constants[Path(path).stem + '.' + name] = value
    rows = []
    direct = re.compile(r'VPhonePatchDeclaration\s*\(\s*identifier\s*:\s*("[^"\n]+"|[\w.]+)')
    properties = re.compile(r'property\s*\(\s*"([^"]+)"')
    for path, content in text.items():
        if not path.endswith('PatchSet.swift'):
            continue
        for match in direct.finditer(content):
            expression = match.group(1)
            if expression == 'identifier':
                # The property helper's parameter; literal call sites below supply IDs.
                continue
            key = expression if '.' in expression else Path(path).stem + '.' + expression
            value = expression[1:-1] if expression.startswith('"') else constants[key]
            rows.append({'id': value, 'path': path, 'line': content[:match.start()].count('\n') + 1, 'expression': expression})
        for match in properties.finditer(content):
            rows.append({'id': match.group(1), 'path': path, 'line': content[:match.start()].count('\n') + 1, 'expression': 'property literal'})
    assert len({r['id'] for r in rows}) == len(rows), 'duplicate ID or parser duplication'
    return sorted(rows, key=lambda r: r['id'])


def presets(ref, declarations):
    paths = subprocess.check_output(['git', '--git-dir', OBJECTS, 'ls-tree', '-r', '--name-only', ref, '--', PRESETS], text=True).splitlines()
    result = {}
    for path in paths:
        if not path.endswith('.plist'):
            continue
        data = source(ref, path).encode()
        value = plistlib.loads(data)
        selection = value['Selection']
        kind = selection['Kind']
        explicit = set(selection.get('Patches', []))
        assert not explicit - declarations, ('preset references unknown declarations', path, explicit - declarations)
        if kind == 'All':
            selected = declarations
        elif kind == 'Block':
            selected = declarations - explicit
        elif kind == 'Select':
            selected = explicit
        else:
            raise ValueError(('unknown selection kind', path, kind))
        result[value['Identifier']] = {
            'path': path, 'sha256': hashlib.sha256(data).hexdigest(),
            'selection_kind': kind, 'explicit_ids': sorted(explicit),
            'patch_sets': value['PatchSets'],
            'selected_ids_before_version_gates': sorted(selected),
            'parameters': value.get('Parameters', {}),
        }
    return result


def main():
    old = collect(PREVIOUS)
    new = collect(TARGET)
    assert len(old) == 117, 'parser must reproduce the historically audited 117 declarations'
    old_ids = {r['id'] for r in old}
    new_ids = {r['id'] for r in new}
    local = json.loads((ROOT / 'research/t10_patch_declarations_2026-10-01.json').read_text())['declarations']
    upstream_links = [(u, r) for r in local for u in r['upstreamIDs']]
    assert len({u for u, _ in upstream_links}) == len(upstream_links), 'ambiguous old mapping; do not discard entries'
    by_upstream = dict(upstream_links)
    rows = []
    for row in new:
        local_row = by_upstream.get(row['id'])
        rows.append({**row, 'local_declaration': local_row['id'] if local_row else None,
                     'local_coverage': local_row['coverage'] if local_row else None,
                     'local_variants': local_row['variants'] if local_row else [],
                     'state': 'old_mapping_requires_revalidation' if local_row else 'no_id_mapping_in_current_catalog',
                     'semantic_equivalence': 'not_established'})
    old_presets = presets(PREVIOUS, old_ids)
    new_presets = presets(TARGET, new_ids)
    preset_changes = {}
    for name in sorted(set(old_presets) | set(new_presets)):
        before = set(old_presets.get(name, {}).get('selected_ids_before_version_gates', []))
        after = set(new_presets.get(name, {}).get('selected_ids_before_version_gates', []))
        preset_changes[name] = {'selected_added_before_version_gates': sorted(after - before),
                               'selected_removed_before_version_gates': sorted(before - after)}
    result = {'target': TARGET, 'previous': PREVIOUS,
              'parser_scope': 'literal declaration/property-call IDs and static string references; no kernel instruction analysis',
              'checks': {'previous_count': len(old), 'target_count': len(new), 'duplicate_target_ids': []},
              'added_ids': sorted(new_ids - old_ids), 'removed_ids': sorted(old_ids - new_ids), 'rows': rows,
              'presets_previous': old_presets, 'presets_target': new_presets, 'preset_changes': preset_changes,
              'intermediate_id_rename': {
                  'introduced_in': '37ed2e65b988b1f9d1758f691772eef1d91233f9', 'renamed_in': '74629ee992ddcfc1b65fe3e86a0610c864846b91',
                  'old_id': 'kernel-exp-paravirt_user_clients', 'new_id': 'kernel-cfw-paravirt_user_clients',
                  'local_migration': 'not_implemented',
                  'evidence': 'fixed Git commit and declaration/preset diff; no kernel instruction analysis',
              },
              'notes': ['相同 ID 不建立相同二进制效果；旧映射需要按目标实现重新验证',
                        '预设选中集合未计算 OS 版本门；不能作为实际启用结果',
                        '未修改执行目录，不把新 ID 自动设为启用',
                        'kernel-exp-paravirt_user_clients 至 kernel-cfw-paravirt_user_clients 的显式用户选择迁移需专门规则；不能用新默认覆盖']}
    (OUT / 'T09_declaration_delta.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['checks', 'preset_changes']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
