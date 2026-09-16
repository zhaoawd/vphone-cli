"""Manual rig2 acceptance; caller must hold the rig2 task lock and keep its VM running."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--classifier', type=Path, required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--prepare', action='store_true', help='wake/unlock the passcode-free rig2 and open Settings before checking preconditions')
    parser.add_argument('--start-y', type=float, default=2790)
    parser.add_argument('--duration-ms', type=int, default=300)
    parser.add_argument('--action', choices=['swipe', 'home', 'hid-baseline', 'hid-hand', 'hid-swipe-up', 'hid-edge-tip', 'hid-edge-tip-fast', 'hid-edge-tip-up', 'hid-edge-flat', 'hid-edge-pending'], default='swipe')
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('label must contain only ASCII letters, digits, hyphen or underscore')
    if not 0 <= args.start_y < 2796 or not 0 <= args.duration_ms <= 60000:
        parser.error('coordinates or duration outside supported range')
    if args.action.startswith('hid-') and (args.start_y != 2790 or args.duration_ms != 300):
        parser.error('isolated HID probe has a fixed trajectory; timing is selected by its mode')
    if not args.output.is_dir() or not args.classifier.is_file():
        parser.error('output directory and compiled classifier must exist')
    if list(args.output.glob(args.label + '-*')):
        parser.error('label already exists; refusing to overwrite evidence')
    spec = importlib.util.spec_from_file_location('rig2', Path(__file__).resolve().parents[1] / 'a3_rig2_probe.py')
    rig2 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rig2)
    rig2.OUT = args.output.resolve()

    def awake(suffix):
        result = rig2.request(dict(t='shell', cmd='/tmp/vphone-a3-display-state', screen=False, label=args.label + suffix))
        if result.get('code') != 0:
            raise RuntimeError(f'display probe unavailable: {result}')
        for key in ['lockstate', 'hasBlankedScreen']:
            if f'com.apple.springboard.{key} status=0 state=0' not in result.get('stdout', ''):
                raise RuntimeError(f'locked, blanked or unknown display state: {result}')

    def state(suffix):
        name = args.label + suffix
        result = rig2.request(dict(t='screenshot', label=name, color=True))
        if not result.get('ok'):
            raise RuntimeError(f'screenshot failed: {result}')
        return subprocess.check_output([str(args.classifier.resolve()), str(rig2.OUT / (name + '.jpg'))], text=True).strip()

    try:
        capabilities = rig2.request(dict(t='capabilities', label=args.label + '-capabilities'))
        if not capabilities.get('guest_connected'):
            raise RuntimeError('guest not connected')
        if args.prepare:
            current = rig2.request(dict(t='shell', cmd='/tmp/vphone-a3-display-state', screen=False,
                                        label=args.label + '-prepare-state'))
            output = current.get('stdout', '')
            if current.get('code') != 0 or any(
                f'com.apple.springboard.{key} status=0 state=0' not in output and
                f'com.apple.springboard.{key} status=0 state=1' not in output
                for key in ['lockstate', 'hasBlankedScreen']
            ):
                raise RuntimeError(f'unknown display state: {current}')
            if 'com.apple.springboard.hasBlankedScreen status=0 state=1' in output:
                rig2.request(dict(t='key', name='power', delay=500, label=args.label + '-wake'))
            if 'com.apple.springboard.lockstate status=0 state=1' in output:
                rig2.request(dict(t='swipe', x1=645, y1=2790, x2=645, y2=1600, ms=300,
                                  delay=1500, label=args.label + '-unlock'))
            rig2.request(dict(t='app_launch', bundle_id='com.apple.Preferences', delay=1500,
                              label=args.label + '-open-settings'))
            rig2.request(dict(t='tap', x=160, y=90, delay=1500,
                              label=args.label + '-settings-top'))
        awake('-before-state')
        if state('-before') != 'SETTINGS':
            raise RuntimeError('Settings root page must be visible before the action')
        action = dict(t='key', name='home') if args.action == 'home' else dict(
            t='swipe', x1=645, y1=args.start_y, x2=645, y2=1600, ms=args.duration_ms)
        if args.action.startswith('hid-'):
            action = dict(t='shell', cmd='/tmp/vphone-a3-hid-swipe ' + args.action.removeprefix('hid-'))
        result = rig2.request(dict(action, delay=2500, label=args.label + '-action'))
        if not result.get('ok') or (action['t'] == 'shell' and result.get('code') != 0):
            raise RuntimeError(f'action failed: {result}')
        observed = []
        # Multiple captures reduce transition-frame errors; they do not prove frame freshness.
        for i in range(3):
            time.sleep(1)
            observed.append(state(f'-after-{i}'))
        awake('-after-state')
        if observed[-2:] == ['HOME', 'HOME']:
            print('PASS Home visible in two final captures')
            return 0
        if observed[-2:] == ['SETTINGS', 'SETTINGS']:
            print('FAIL still in Settings')
            return 1
        print(f'INCONCLUSIVE inspect screenshots: {observed}')
        return 2
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'PRECONDITION/PROBE ERROR: {error}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
