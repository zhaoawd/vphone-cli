#!/usr/bin/env python3
"""Convert a pip --dry-run --ignore-installed --report result to a platform hash lock."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    records = []
    for item in report['install']:
        download = item['download_info']
        records.append({'name': item['metadata']['name'], 'version': item['metadata']['version'],
                        'url': download['url'], 'sha256': download['archive_info']['hashes']['sha256']})
    records.sort(key=lambda r: r['name'].lower())
    content = '# Generated from pip resolution; scoped to ' + str(report['environment']) + '\n\n'
    content += '\n\n'.join(f"{r['name']}=={r['version']} \\\n    --hash=sha256:{r['sha256']}" for r in records) + '\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content)
    args.output.with_suffix('.json').write_text(json.dumps({'environment': report['environment'],
        'requirements_sha256': hashlib.sha256((Path(__file__).resolve().parents[1] / 'requirements.txt').read_bytes()).hexdigest(), 'packages': records}, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
