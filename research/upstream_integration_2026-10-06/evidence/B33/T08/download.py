#!/usr/bin/env python3
"""下载 B29 已固定的软件包，逐文件核对大小和 SHA256。"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import urllib.request
import subprocess

repo = Path(__file__).resolve().parents[5]
historical = repo / 'research/upstream_integration_2026-10-06/evidence/B29/T08/packages'
output = repo / '.build/research-b33/packages'
output.mkdir(parents=True, exist_ok=True)
items = json.loads((historical / 'downloads.json').read_text())
items.append({'package': 'wiki.qaq.irisin', 'version': '4.5.26', 'url': 'https://github.com/Lakr233/Irisin/releases/download/v4.5.26/wiki.qaq.irisin_4.5.26_iphoneos-arm64e.deb', 'path': 'wiki.qaq.irisin_4.5.26_iphoneos-arm64e.deb', 'bytes': 5710984, 'sha256': '0ced7ab0e678aca92c2f684d7a311c32f5fa4540166b2d14a7d8079bcc1b12bf'})

def guard():
    s = os.statvfs(output)
    assert s.f_bavail * s.f_frsize >= 5 * 1024**3, 'STOP: disk below 5 GiB'

def download(item):
    guard()
    p = output / Path(item['path']).name
    if not p.exists():
        # curl 使用本机既有代理配置；urllib 在本次环境部分端点 TLS EOF。
        process = subprocess.Popen(['curl', '-fLsS', '--retry', '3', '--max-time', '120', item['url']], stdout=subprocess.PIPE)
        with p.open('xb') as stream:
            while block := process.stdout.read(256 * 1024):
                guard()
                stream.write(block)
        assert process.wait() == 0, item['package']
    raw = p.read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    assert len(raw) == item['bytes'] and sha == item['sha256'], item['package']
    return dict(item, path=str(p), ok=True, observed_sha256=sha)

with ThreadPoolExecutor(max_workers=4) as pool:
    result = list(pool.map(download, items))
(output / 'downloads.json').write_text(json.dumps(result[:-1], indent=2) + '\n')
(repo / 'research/upstream_integration_2026-10-06/evidence/B33/T08/downloads.json').write_text(json.dumps(result, indent=2) + '\n')
print(len(result), 'verified packages', sum(r['bytes'] for r in result), 'bytes')
