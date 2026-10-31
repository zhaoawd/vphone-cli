#!/usr/bin/env python3
"""Validate a captured consumer-probe record; never query or change a VM."""
import argparse
import json
import math
from pathlib import Path

BUNDLE_ID = 'org.vphone.acceptance.t52.20261022'


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def verify(record, *, run_id, pid, mode, expected):
    if (record.get('schemaVersion') != 1 or record.get('bundleID') != BUNDLE_ID
            or record.get('runID') != run_id or record.get('pid') != pid
            or record.get('mode') != mode or not run_id or pid <= 0):
        raise ValueError('Consumer identity, phase or named run differs')
    started = record.get('startedAt')
    events = record.get('events')
    if not number(started) or started <= 0 or not isinstance(events, list) or not events:
        raise ValueError('Missing consumer events or start time')
    for event in events:
        if not isinstance(event, dict) or not number(event.get('time')) or event['time'] < started:
            raise ValueError('Invalid or stale consumer event')
        if event.get('type') in ('camera_error', 'location_error'):
            raise ValueError('Consumer reported an error')
    if mode == 'location':
        samples = [event for event in events if event.get('type') == 'location_callback']
        if len(samples) < 2:
            raise ValueError('Two real consumer callbacks are required')
        fields = ('latitude', 'longitude', 'altitude', 'horizontalAccuracy', 'verticalAccuracy', 'speed', 'course')
        if set(expected) != set(fields) or not all(number(v) for v in expected.values()):
            raise ValueError('All seven expected location fields are required')
        for sample in samples:
            if not number(sample.get('timestamp')) or sample['timestamp'] < started - 1:
                raise ValueError('Location sample predates the named run')
            if not all(number(sample.get(key)) for key in fields):
                raise ValueError('Invalid consumer location fields')
        def matches(sample):
            return all(abs(sample[key] - expected[key]) <= (1e-6 if key in fields[:2] else .01)
                       for key in fields)
        if not all(matches(sample) for sample in samples[-2:]):
            raise ValueError('Latest consumer locations differ from the sent point')
        return dict(state='passed', mode=mode, runID=run_id, pid=pid, callbacks=len(samples),
                    scope='CLLocationManager delegate delivery for the named point')
    if mode == 'camera':
        devices = [event for event in events if event.get('type') == 'camera_device']
        messages = [event.get('message') for event in events if event.get('type') == 'camera_metadata']
        if not isinstance(expected, str) or not expected:
            raise ValueError('Unique nonempty expected QR content is required')
        if (not devices or any(event.get('uniqueID') != 'vphone:vcam:0' for event in devices)
                or not messages or any(message != expected for message in messages)):
            raise ValueError('Virtual device or consumer QR metadata differs')
        if not any(event.get('type') == 'camera_started' for event in events):
            raise ValueError('Capture start was not observed')
        return dict(state='passed', mode=mode, runID=run_id, pid=pid, callbacks=len(messages),
                    scope='AVCaptureMetadataOutput delivery of the named QR; business apps untested')
    raise ValueError('Unsupported consumer phase')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=Path)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--mode', choices=('location', 'camera'), required=True)
    parser.add_argument('--expected', required=True, help='JSON object for location, exact text for camera')
    args = parser.parse_args()
    expected = json.loads(args.expected) if args.mode == 'location' else args.expected
    print(json.dumps(verify(json.loads(args.record.read_text()), run_id=args.run_id,
                           pid=args.pid, mode=args.mode, expected=expected), indent=2))


if __name__ == '__main__':
    main()
