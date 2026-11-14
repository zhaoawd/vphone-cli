import assert from 'node:assert/strict';
import { test } from 'node:test';
import { clockOffset, darkPhase } from './f5-hold-report.mjs';

const sample = (sent, received, uptime, boot = 'boot-a') => ({ sent, received, guest_uptime_ms: uptime, boot_session_uuid: boot });
test('intersects request bounds instead of treating the midpoint as a timestamp', () => {
    assert.deepEqual(clockOffset([sample(101, 109, 1000), sample(105, 108, 1001)]),
        { lower: -896, upper: -893, uncertaintyMs: 3 });
});
test('rejects offset drift and guest restarts instead of widening the alignment', () => {
    assert.throws(() => clockOffset([sample(100, 101, 1000), sample(200, 201, 1000)]), /inconsistent/);
    assert.throws(() => clockOffset([sample(100, 101, 1000), sample(100, 101, 1000, 'boot-b')]), /boot session/);
    assert.throws(() => clockOffset([sample(100, 99, 1000)]), /Invalid/);
});
test('keeps uncertain boundary samples out of commit/release intervals', () => {
    const on = { lower: 100, upper: 110 }, off = { lower: 200, upper: 210 };
    assert.equal(darkPhase(90, on, off), 'before_commit_request');
    assert.equal(darkPhase(150, on, off), 'between_commit_and_release_requests');
    assert.equal(darkPhase(220, on, off), 'after_release_request');
    assert.equal(darkPhase(111, on, off), 'boundary_uncertain');
    assert.equal(darkPhase(199, on, off), 'boundary_uncertain');
    assert.equal(darkPhase(150, undefined, off), 'missing_hold_boundary');
});
