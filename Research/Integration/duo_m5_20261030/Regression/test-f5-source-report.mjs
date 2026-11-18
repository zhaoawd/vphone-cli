import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareTrial, continuityFailures, renderWindow } from './f5-source-report.mjs';

const trial = { name: '0-1-open', requestMoviePTS: 1, observationEndAfterRequestMs: 600,
    darkSamples: [{ moviePTS: 1.2, afterRequestMs: 200 }],
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

test('uses the bounded render time when PNG transport extends beyond a repetition', () => {
    const offset = { lower: 150, upper: 155 };
    const timed = sample(1100, 1500, 'a', {
        metadata: { render_started_uptime: 1.1, render_finished_uptime: 1.11 },
    });
    assert.deepEqual(renderWindow(timed, offset), { lower: 1250, upper: 1265, timing: 'guest_render' });
    const withoutTiming = compareTrial(trial, 50, [sample(1100, 1600)]);
    assert.equal(withoutTiming.repeatedMovieLuma[0].containedGuestRequests.length, 0);
    const withTiming = compareTrial(trial, 50, [{ ...timed, received: 1600, renderWindow: renderWindow(timed, offset) }]);
    assert.equal(withTiming.repeatedMovieLuma[0].containedGuestRequests.length, 1);
    assert.throws(() => renderWindow({ ...timed, received: 1249 }, offset), /outside its RPC window/);
    assert.throws(() => renderWindow({ ...timed, metadata: { render_started_uptime: 1.1 } }, offset), /Invalid guest render uptime/);
});

test('requires ordered non-dark content differences at identical source and orientation', () => {
    const source = { display_id: 7, frontboard_interface_orientation: 1 };
    const first = sample(1200, 1250, 'a', { source });
    for (const second of [
        sample(1230, 1280, 'b', { source }),
        sample(1260, 1280, 'a', { source }),
        sample(1260, 1280, 'b', { source, state: 'dark' }),
        sample(1260, 1280, 'b', { source: { ...source, frontboard_interface_orientation: 4 } }),
    ]) {
        assert.equal(compareTrial(trial, 50, [first, second]).repeatedMovieLuma[0].sourceContentChanged, false);
    }
    const result = compareTrial(trial, 50, [first, sample(1260, 1280, 'b', { source })]);
    assert.equal(result.repeatedMovieLuma[0].sourceContentChanged, true);
});

test('records changes on the outgoing panel without treating them as a target panel update', () => {
    const outgoing = { source: { display_id: 1 }, panel: 'LCD', targetPanel: false };
    const result = compareTrial(trial, 50, [sample(1200, 1250, 'a', outgoing), sample(1260, 1300, 'b', outgoing)]);
    const repeat = result.repeatedMovieLuma[0];
    assert.equal(repeat.containedOutgoingRequests.length, 2);
    assert.equal(repeat.outgoingSourceContentChanged, true);
    assert.equal(repeat.sourceContentChanged, false);
});

test('reports successive changes at stable source geometry and orientation outside MOV repetitions', () => {
    const portrait = { display_id: 7, frontboard_interface_orientation: 1, currentOrientation: 'rot0' };
    const landscape = { ...portrait, frontboard_interface_orientation: 4 };
    const result = compareTrial({ ...trial, repeats: [] }, 50, [
        sample(1100, 1140, 'a', { source: portrait }),
        sample(1130, 1150, 'b', { source: portrait }), // overlapping time bounds
        sample(1180, 1200, 'c', { source: portrait }),
        sample(1250, 1270, 'c', { source: portrait }), // unchanged raster
        sample(1300, 1320, 'd', { source: portrait }),
        sample(1350, 1370, 'e', { source: landscape }),
        sample(1400, 1420, 'f', { source: landscape, state: 'dark' }),
        sample(1450, 1470, 'g', { source: landscape }),
    ]);
    assert.deepEqual(result.stableTargetSourceRuns.map(run => ({
        orientation: run.source.frontboard_interface_orientation,
        samples: run.samples,
        changes: run.changes,
        guaranteedSpanMs: run.guaranteedSpanMs,
    })), [
        { orientation: 1, samples: 5, changes: 2, guaranteedSpanMs: 160 },
        { orientation: 4, samples: 1, changes: 0, guaranteedSpanMs: 0 },
        { orientation: 4, samples: 1, changes: 0, guaranteedSpanMs: 0 },
    ]);
});

test('strict acceptance preserves unavailable, near-black, unsynchronized content and direction failures', () => {
    const result = compareTrial({ ...trial, darkSamples: [] }, 50, [
        sample(1200, 1250, 'a', { state: 'dark' }),
        sample(1260, 1280, null, { sourceState: 'source_changed' }),
    ]);
    const evidence = { ...result, handoffVerdict: 'confirmed',
        orientation: { requested: 'portrait', before: 0, after: 90, sampled: [0, 90] } };
    assert.deepEqual(continuityFailures(evidence),
        ['near_black_native', 'native_unavailable', 'source_update_unverified', 'orientation_changed_or_unverified']);
});

test('strict acceptance checks native FrontBoard direction even when SpringBoard stays at the requested angle', () => {
    const native = { display_id: 7, frontboard_interface_orientation: 4, currentOrientation: 'rot0' };
    const result = compareTrial({ ...trial, darkSamples: [], repeats: [] }, 50,
        [sample(1200, 1250, 'a', { source: native })]);
    const evidence = { ...result, handoffVerdict: 'confirmed',
        orientation: { requested: 'portrait', before: 0, after: 0, sampled: [0] } };
    assert.deepEqual(result.targetOrientations, [{ frontboard: 4, coreAnimation: 'rot0' }]);
    assert.deepEqual(continuityFailures(evidence), ['orientation_changed_or_unverified']);
    assert.deepEqual(continuityFailures({ ...evidence, targetOrientations: [{ frontboard: 1, coreAnimation: 'rot0' }] }), []);
});
