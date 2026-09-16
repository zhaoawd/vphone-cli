"""Manual rig2-only input acceptance. Caller holds the task lock; inspect GUI evidence.

Scaling/disconnect use the temporary a3_acceptance host hook recorded with the run,
not a production protocol command. The script does not start or stop any VM.
"""
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
    parser.add_argument('--mode', choices=['basic', 'scaling', 'disconnect'], required=True)
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('invalid label')
    if not args.output.is_dir() or list(args.output.glob(args.label + '-*')):
        parser.error('output must exist and label must be unused')
    spec = importlib.util.spec_from_file_location('rig2', Path(__file__).resolve().parents[1] / 'a3_rig2_probe.py')
    rig2 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rig2)
    rig2.OUT = args.output.resolve()
    count = 0

    def request(step, **fields):
        nonlocal count
        count += 1
        label = f'{args.label}-{count:02d}-{step}'
        result = rig2.request(dict(delay=1500, color=True, **fields, label=label))
        if not result.get('ok') or (fields['t'] == 'shell' and result.get('code') != 0):
            raise RuntimeError(f'{label}: {result}')
        print(label, result, flush=True)
        return result, rig2.OUT / (label + '.jpg')

    def expect_screen(name, expected):
        # Do not use a transition frame as the final verdict.
        for index in range(2):
            time.sleep(1)
            _, path = request(f'{name}-{index}', t='screenshot')
            state = subprocess.check_output([str(args.classifier.resolve()), str(path)], text=True).strip()
            if state != expected:
                raise RuntimeError(f'{path}: expected {expected}, got {state}')

    def home():
        request('home-key', t='key', name='home')
        expect_screen('home', 'HOME')

    def tap_settings():
        request('tap-settings', t='tap', x=790, y=1955)
        request('settings-scroll-to-top', t='tap', x=160, y=90)
        expect_screen('settings', 'SETTINGS')

    def home_swipe():
        request('home-swipe', t='swipe', x1=645, y1=2790, x2=645, y2=1600, ms=300)
        expect_screen('home-swipe', 'HOME')

    caps, _ = request('capabilities', t='capabilities', screen=False)
    if not caps.get('guest_connected') or 'touch_edge' not in caps.get('guest_capabilities', []):
        raise RuntimeError('requires the fixed guest with touch_edge')
    state, _ = request('initial-state', t='shell', cmd='/tmp/vphone-a3-display-state', screen=False)
    out = state.get('stdout', '')
    for key in ['lockstate', 'hasBlankedScreen']:
        if not any(f'com.apple.springboard.{key} status=0 state={value}' in out for value in [0, 1]):
            raise RuntimeError('unknown display state')
    if 'com.apple.springboard.hasBlankedScreen status=0 state=1' in out:
        request('wake', t='key', name='power')
    if 'com.apple.springboard.lockstate status=0 state=1' in out:
        request('unlock', t='swipe', x1=645, y1=2790, x2=645, y2=1600, ms=300)
    home()

    if args.mode == 'basic':
        tap_settings()
        request('list-drag', t='swipe', x1=645, y1=2200, x2=645, y2=900, ms=450)
        request('list-drag-final', t='screenshot')
        home()
        request('long-press', t='swipe', x1=790, y1=1955, x2=790, y2=1955, ms=1500)
        request('long-press-final', t='screenshot')
        home()
    elif args.mode == 'scaling':
        for scale in [0.75, 1.0, 1.25]:
            result, _ = request('resize', t='a3_acceptance', scale=scale, screen=False)
            if not result.get('guest_touch'):
                raise RuntimeError('guest route not selected')
            tap_settings()
            home_swipe()
        request('restore-size', t='a3_acceptance', scale=1.0, screen=False)
    else:
        tap_settings()
        before, _ = request('route-before', t='a3_acceptance', screen=False)
        request('down', t='a3_acceptance', phase=0, x=645, y=2200, screen=False)
        time.sleep(.3)
        request('held-down-screen', t='screenshot')
        request('move', t='a3_acceptance', phase=1, x=645, y=1700, screen=False)
        time.sleep(.5)
        request('held-move-screen', t='screenshot')
        request('disconnect', t='a3_acceptance', disconnect=True, screen=False)
        time.sleep(1)
        caps, _ = request('disconnected-caps', t='capabilities', screen=False)
        if caps.get('guest_connected'):
            raise RuntimeError('disconnect did not take effect')
        request('orphan-up', t='a3_acceptance', phase=3, x=645, y=1700, screen=False)
        request('released-screen', t='screenshot')
        # A fresh native gesture is distinct from the discarded guest gesture.
        request('disconnected-native-drag', t='swipe', x1=645, y1=2200, x2=645, y2=900, ms=450)
        request('native-final', t='screenshot')
        request('reconnect', t='a3_acceptance', reconnect=True, screen=False)
        for index in range(15):
            time.sleep(.5)
            caps, _ = request('reconnect-caps', t='capabilities', screen=False)
            if caps.get('guest_connected'):
                break
        else:
            raise RuntimeError('reconnect timed out')
        after, _ = request('route-after', t='a3_acceptance', screen=False)
        if not after.get('guest_touch') or after.get('touch_session') == before.get('touch_session'):
            raise RuntimeError('new guest session not selected')
        request('stale-move', t='a3_acceptance', phase=1, x=645, y=1200, screen=False)
        request('stale-up', t='a3_acceptance', phase=3, x=645, y=1200, screen=False)
        home()
        tap_settings()
        home_swipe()
    state, _ = request('final-state', t='shell', cmd='/tmp/vphone-a3-display-state', screen=False)
    if any(f'com.apple.springboard.{key} status=0 state=0' not in state.get('stdout', '')
           for key in ['lockstate', 'hasBlankedScreen']):
        raise RuntimeError('final display not awake and unlocked')
    print('PASS assertions; manually inspect drag/long-press/release screenshots', flush=True)


if __name__ == '__main__':
    main()
