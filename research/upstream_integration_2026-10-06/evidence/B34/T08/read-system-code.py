#!/usr/bin/env python3
"""读取研究副本中指定的 SpringBoard 方法，不修改方法或返回值。"""
import json
from pathlib import Path
import sys
REPO = Path(__file__).resolve().parents[5]
sys.path.insert(0, str(REPO / 'research/upstream_integration_2026-10-06/evidence/B33/T08'))
import client
client.check()
sys.path.insert(0, str(REPO / '.build/research-b33/python'))
import frida
ep = json.loads((REPO / '.build/research-b33/frida-endpoint.private.json').read_text())
device = frida.get_device_manager().add_remote_device(f"{ep['ip']}:{ep['port']}", token=Path(ep['token_file']).read_text())
pid = next(p.pid for p in device.enumerate_processes() if p.name == 'SpringBoard')
session = device.attach(pid)
script = session.create_script((REPO / 'research/upstream_integration_2026-10-06/evidence/B32/T08/fixture-policy.js').read_text())
script.load()
try:
    specs = json.loads(Path(sys.argv[1]).read_text())
    rows = [script.exports_sync.code(c, s) for c, s in specs]
    Path(sys.argv[2]).write_text(json.dumps(rows, indent=2) + '\n')
    for r in rows:
        print(r['class'], r['selector'], len(r.get('instructions', [])))
        for ins in r.get('instructions', []):
            if ins.get('target_symbol') and 'objc_msgSend' in ins['target_symbol']:
                print(ins['target_symbol'].split('objc_msgSend$')[-1])
finally:
    script.unload()
    session.detach()
