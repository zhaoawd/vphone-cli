import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { alignMovie } from './f5-mov-align.mjs';

const origin = 123456789012345678n; // Keep absolute nanoseconds out of Number.
const clock = { host_uptime_ns_at_monotonic_zero: origin.toString() };
const log = `[record] first frame - uptime_ns=${origin - 1000000000n} file=/test/movie.mov\n`;
const timing = { samples: [0, 0.5, 1, 1.4, 2, 3].map(pts => ({ pts })), repeats: [
    { start: 0, end: 0.5, images: 2, dark: false, spanMs: 500, maxIntervalMs: 500 },
    { start: 1, end: 1.4, images: 2, dark: false, spanMs: 400, maxIntervalMs: 400 },
] };
const trials = [{ name: '0-1-open', action: { sent: 100, received: 200, response: { ok: true } },
    samples: [{ sent: 90, received: 150 }, { sent: 390, received: 500 }] }];

test('aligns a repeat crossing the request and excludes baseline observations', () => {
    const report = alignMovie(timing, log, clock, trials);
    assert.equal(report.movieZeroAfterSamplerOriginMs, -1000);
    assert.equal(report.trials[0].requestMoviePTS, 1.1);
    assert.equal(report.trials[0].repeats.length, 1);
    assert.equal(report.trials[0].repeats[0].startAfterRequestMs, -100);
    assert.equal(report.trials[0].repeats[0].endAfterRequestMs, 300);
    assert.equal(report.trials[0].repeats[0].maxIntervalMs, 400);
});
test('rejects missing and ambiguous origins rather than using the wall clock', () => {
    assert.throws(() => alignMovie(timing, '', clock, trials), /exactly one/);
    assert.throws(() => alignMovie(timing, log + log, clock, trials), /exactly one/);
    assert.throws(() => alignMovie(timing, log, {}, trials), /wall clock/);
});
test('aligns individual dark samples without treating them as a continuous interval', () => {
    const darkTiming = { ...timing, samples: timing.samples.map(frame => ({ ...frame, dark: frame.pts === 1 || frame.pts === 1.4 })) };
    const trial = alignMovie(darkTiming, log, clock, trials).trials[0];
    assert.deepEqual(trial.darkSamples, [{ moviePTS: 1.4, afterRequestMs: 300 }]);
    assert.equal(trial.repeats[0].dark, false);
});
test('rejects incomplete recordings and failed requests', () => {
    assert.throws(() => alignMovie(timing, log, clock, [{ ...trials[0], samples: [{ received: 2500 }] }]), /does not cover/);
    assert.throws(() => alignMovie(timing, log, clock, [{ ...trials[0], action: { ...trials[0].action, response: { ok: false } } }]), /successful request/);
});
test('Swift capture timestamps fall within Node monotonic invocation bounds', { skip: !process.env.VPHONE_RECORDING_CLOCK_TEST }, () => {
    for (let i = 0; i < 3; i++) {
        const before = process.hrtime.bigint();
        const child = spawnSync(process.env.VPHONE_RECORDING_CLOCK_TEST, ['--clock'], { encoding: 'utf8' });
        const after = process.hrtime.bigint();
        assert.equal(child.status, 0, child.stderr);
        const captured = BigInt(child.stdout.trim());
        assert.ok(before <= captured && captured <= after, `Swift ${captured} outside Node [${before}, ${after}]`);
    }
});
