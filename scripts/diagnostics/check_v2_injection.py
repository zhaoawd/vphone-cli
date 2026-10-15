#!/usr/bin/env python3
"""Read-only R4 signal: launchdhook in pid 1 and SystemHook in cameracaptured."""
import argparse
import json
import subprocess


def check(cli, library, vm, components):
    def request(arguments):
        result = subprocess.run([cli, 'guest', *arguments, '--library-root', library],
                                capture_output=True, text=True, timeout=90)
        value = json.loads(result.stdout)
        if result.returncode or not value.get('ok'):
            raise RuntimeError(value.get('error', result.stderr))
        return value
    environment = request(['env', 'status', vm, '--components', components])
    processes = request(['rpc', vm, 'processes.list'])['result']['processes']
    load = environment['load']
    libraries = {row['name']: row for row in load['libraries']}
    camera = {p['pid'] for p in processes if p['name'] == 'cameracaptured'}
    launch = libraries['launchdhook-vphone.dylib']
    hook = libraries['SystemHook-vphone.dylib']
    passed = (load['source'] == 'environment.loaded' and load.get('complete') is True
              and 1 in launch['current_pids'] and bool(camera)
              and camera.issubset(set(hook['current_pids'])))
    report = {'passed': passed, 'load': load, 'cameracaptured_pids': sorted(camera),
              'SystemHook_current_pids': hook['current_pids']}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True)
    parser.add_argument('--library', required=True)
    parser.add_argument('--vm', required=True)
    parser.add_argument('--components', required=True)
    args = parser.parse_args()
    print(json.dumps(report := check(args.cli, args.library, args.vm, args.components), sort_keys=True))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
