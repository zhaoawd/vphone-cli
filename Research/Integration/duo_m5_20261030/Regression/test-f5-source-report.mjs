import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareTrial } from './f5-source-report.mjs';

const trial = { name: '0-1-open', requestMoviePTS: 1, darkSamples: [{ moviePTS: 1.2, afterRequestMs: 200 }],
    repeats: [{ start: 1.1, end: 1.5, spanMs: 400, dark: false }] };
const sample = (sent, received, hash = 'a', extra = {}) => ({ sent, received, hash, state: 'visible',
    identityStable: true, targetPanel: true, ...extra });

test('requires full containment with a MOV quantization margin', () => {
    const result = compareTrial(trial, 50, [sample(1149, 1200), sample(1151, 1220), sample(1153, 1220), sample(1300, 1549)]);
    assert.equal(result.repeatedMovieLuma[0].containedGuestRequests.length, 1);
    assert.equal(result.repeatedMovieLuma[0].containedGuestRequests[0].sent, 1153);
});
test('excludes unavailable, wrong-panel and unstable-identity samples from repeat comparison', () => {
    const samples = [sample(1160, 1200, null), sample(1210, 1250, 'b', { targetPanel: false }),
        sample(1260, 1300, 'c', { identityStable: false }), sample(1310, 1350, 'd'), sample(1360, 1400, 'e')];
    const result = compareTrial(trial, 50, samples);
    assert.equal(result.unavailable, 1);
    assert.equal(result.repeatedMovieLuma[0].distinctGuestLuma, 2);
});
test('reports overlapping capture windows without calling them identical instants', () => {
    const result = compareTrial(trial, 50, [sample(1240, 1260, 'a', { state: 'dark' }), sample(1270, 1290)]);
    assert.equal(result.movieDark[0].overlappingGuestRequests.length, 1);
    assert.equal(result.guestDark[0].sentAfterRequestMs, 190);
    assert.equal(result.guestDark[0].receivedAfterRequestMs, 210);
});
