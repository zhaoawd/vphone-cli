// Bound guest renders on the host timeline. Older recordings use RPC windows.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { clockOffset } from './f5-hold-report.mjs';

export function renderWindow(sample, offset) {
    const { sent, received, metadata } = sample;
    const start = metadata?.render_started_uptime, end = metadata?.render_finished_uptime;
    if (![sent, received].every(Number.isFinite) || sent > received) throw Error('Invalid guest request window');
    if (start === undefined && end === undefined) return { lower: sent, upper: received, timing: 'rpc' };
    if (![start, end].every(Number.isFinite) || start < 0 || start > end) throw Error('Invalid guest render uptime');
    if (!offset) return { lower: sent, upper: received, timing: 'rpc' };
    const lower = Math.max(sent, start * 1000 + offset.lower);
    const upper = Math.min(received, end * 1000 + offset.upper);
    if (lower > upper) throw Error('Guest render uptime falls outside its RPC window');
    return { lower, upper, timing: 'guest_render' };
}

function windowOf(sample) {
    return sample.renderWindow ?? { lower: sample.sent, upper: sample.received };
}

function showsSourceChange(samples) {
    return samples.some((sample, i) => sample.source && sample.state === 'visible' &&
        samples.slice(i + 1).some(next => next.state === 'visible' && next.hash !== sample.hash &&
            isDeepStrictEqual(sample.source, next.source) && windowOf(sample).upper < windowOf(next).lower));
}

function stableTargetSourceRuns(samples, start, end) {
    const runs = [];
    let active, lastChange;
    for (const sample of samples) {
        const window = windowOf(sample);
        if (window.lower < start || window.upper > end || !sample.hash || !sample.identityStable ||
            !sample.targetPanel || sample.state !== 'visible' || !sample.source) {
            active = undefined;
            continue;
        }
        if (!active || !isDeepStrictEqual(active.source, sample.source)) {
            active = {
                source: sample.source,
                firstRender: window,
                lastRender: window,
                samples: 0,
                changes: 0,
                guaranteedSpanMs: 0,
            };
            runs.push(active);
            lastChange = sample;
        }
        active.samples++;
        active.lastRender = window;
        active.guaranteedSpanMs = Math.max(0, window.lower - active.firstRender.upper);
        if (window.lower > windowOf(lastChange).upper && sample.hash !== lastChange.hash) {
            active.changes++;
            lastChange = sample;
        }
    }
    return runs;
}

export function compareTrial(trial, movieOffsetMs, guestSamples) {
    const sent = movieOffsetMs + trial.requestMoviePTS * 1000;
    const endOfObservation = sent + trial.observationEndAfterRequestMs;
    const outgoingPanel = trial.name.endsWith('-open') ? 'LCD' : 'VPhone Duo Inner';
    const marginMs = 2; // Greater than one tick of the current 1/600 MOV time base.
    const targetSamples = guestSamples.filter(row => row.hash && row.identityStable && row.targetPanel &&
        windowOf(row).lower >= sent && windowOf(row).upper <= endOfObservation);
    const targetOrientations = targetSamples.map(row => ({
        frontboard: row.source?.frontboard_interface_orientation ?? null,
        coreAnimation: row.source?.currentOrientation ?? null,
    }));
    return {
        name: trial.name,
        guestSamples: guestSamples.length,
        unavailable: guestSamples.filter(row => !row.hash).length,
        guestDark: guestSamples.filter(row => row.state === 'dark').map(row => ({ ...row,
            sentAfterRequestMs: row.sent - sent, receivedAfterRequestMs: row.received - sent })),
        movieDark: trial.darkSamples.map(frame => ({ ...frame,
            overlappingGuestRequests: guestSamples.filter(row => windowOf(row).lower <= sent + frame.afterRequestMs + marginMs &&
                windowOf(row).upper >= sent + frame.afterRequestMs - marginMs),
        })),
        repeatedMovieLuma: trial.repeats.filter(row => !row.dark && row.spanMs >= 150).map(row => {
            const start = movieOffsetMs + row.start * 1000;
            const end = movieOffsetMs + row.end * 1000;
            const contained = guestSamples.filter(sample => sample.hash && sample.identityStable &&
                windowOf(sample).lower >= start + marginMs && windowOf(sample).upper <= end - marginMs);
            const target = contained.filter(sample => sample.targetPanel);
            const outgoing = contained.filter(sample => !sample.targetPanel && sample.panel === outgoingPanel);
            return { ...row, containedGuestRequests: target,
                distinctGuestLuma: new Set(target.map(sample => sample.hash)).size,
                sourceContentChanged: showsSourceChange(target),
                containedOutgoingRequests: outgoing,
                outgoingSourceContentChanged: showsSourceChange(outgoing) };
        }),
        targetSamplesInObservation: targetSamples.length,
        stableTargetSourceRuns: stableTargetSourceRuns(guestSamples, sent, endOfObservation),
        targetOrientations: targetOrientations.filter((value, index) =>
            targetOrientations.findIndex(first => isDeepStrictEqual(first, value)) === index),
        retriesInObservation: guestSamples.filter(row => row.sourceAttempts === 2 && row.sent <= endOfObservation &&
            row.received >= sent).length,
        unavailableInObservation: guestSamples.filter(row => !row.hash && row.sent <= endOfObservation &&
            row.received >= sent),
    };
}

export function continuityFailures(trial) {
    const failures = [];
    const targetDark = trial.guestDark.filter(row => row.targetPanel && row.identityStable);
    if (trial.handoffVerdict !== 'confirmed') failures.push('unconfirmed_handoff');
    if (!trial.targetSamplesInObservation) failures.push('missing_target_native_samples');
    if (targetDark.length) failures.push('near_black_native');
    if (trial.unavailableInObservation.length) failures.push('native_unavailable');
    if (trial.movieDark.length) failures.push('near_black_mov');
    if (trial.repeatedMovieLuma.some(row => !row.sourceContentChanged)) failures.push('source_update_unverified');
    const degrees = { portrait: 0, 'landscape-left': 90 }[trial.orientation.requested];
    const frontboard = { portrait: 1, 'landscape-left': 4 }[trial.orientation.requested];
    if (degrees === undefined || trial.orientation.before !== degrees || trial.orientation.after !== degrees ||
        !trial.orientation.sampled.length ||
        trial.orientation.sampled.some(value => value !== degrees) || !trial.targetOrientations.length ||
        trial.targetOrientations.some(value => value.frontboard !== frontboard)) failures.push('orientation_changed_or_unverified');
    return failures;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [root, mode, ...extra] = process.argv.slice(2);
    if (!root || (mode && mode !== '--require-native-continuity') || extra.length) {
        throw Error('Usage: f5-source-report.mjs <paired recording evidence directory> [--require-native-continuity]');
    }
    const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
    const alignment = read('movie-alignment.json');
    const clock = read('motion/samples/clock.json');
    const handoffRows = fs.readFileSync(path.join(root, 'motion/handoff.tsv'), 'utf8').trim().split('\n');
    const handoffColumns = handoffRows.shift().split('\t');
    const handoffs = new Map(handoffRows.map(line => {
        const cells = line.split('\t');
        return [cells[handoffColumns.indexOf('trial')], cells[handoffColumns.indexOf('verdict')]];
    }));
    const rows = fs.readFileSync(path.join(root, 'motion/dual.tsv'), 'utf8').trimEnd().split('\n');
    const columns = rows.shift().split('\t');
    if (!columns.includes('luma_sha256') || !columns.includes('sample_file')) throw Error('Regenerate dual.tsv with luma hashes');
    const classified = rows.map(line => Object.fromEntries(line.split('\t').map((value, i) => [columns[i], value])))
        .filter(row => row.source === 'guest' && row.sample_file);
    const results = alignment.trials.map(trial => {
        const expected = trial.name.endsWith('-open') ? 'VPhone Duo Inner' : 'LCD';
        const folder = `motion/samples/${trial.name}`;
        const offset = clock.guest_clock
            ? clockOffset([...read(`${folder}/clock-before.json`), ...read(`${folder}/clock-after.json`)])
            : null;
        const samples = read(`${folder}/guest-samples.json`).map(sample => {
            const row = classified.find(row => row.trial === trial.name && row.sample_file === sample.file);
            if (sample.file && !/^[a-f0-9]{64}$/.test(row?.luma_sha256 ?? '')) throw Error('Missing guest image classification');
            const source = sample.metadata?.source, after = sample.metadata?.source_after;
            return { file: sample.file ?? null, sent: sample.sent, received: sample.received,
                renderWindow: renderWindow(sample, offset),
                state: row?.state ?? 'unavailable', hash: row?.luma_sha256 ?? null,
                panel: source?.name ?? null, displayID: source?.display_id ?? null,
                identityStable: sample.metadata?.available === true && Number.isInteger(source?.display_id) &&
                    isDeepStrictEqual(source, after),
                source: source ?? null, sourceState: sample.metadata?.state ?? null,
                sourceAttempts: sample.metadata?.source_attempts ?? null,
                targetPanel: source?.name === expected,
                reason: sample.metadata?.reason ?? sample.error ?? null };
        });
        const result = compareTrial(trial, alignment.movieZeroAfterSamplerOriginMs, samples);
        result.clockOffset = offset;
        result.handoffVerdict = handoffs.get(trial.name) ?? 'unconfirmed';
        const context = read(`motion/samples/${trial.name}/action.json`);
        result.orientation = { requested: context.orientation, before: context.before?.degrees, after: context.after?.degrees,
            sampled: [...new Set(read(`motion/samples/${trial.name}/samples.json`).map(sample => sample.state?.degrees ?? null))] };
        result.failures = continuityFailures(result);
        return result;
    });
    console.log(JSON.stringify({
        scope: 'Calibrated guest render windows or original RPC bounds versus host MOV observations. Distinct luma in ordered, non-dark renders with identical display metadata shows a sampled content difference. Native capture can affect rendering.',
        guestCapture: clock.guest_capture,
        trials: results,
    }, null, 2));
    if (mode && (clock.guest_capture !== 'native' || !results.length || results.some(row => row.failures.length))) process.exitCode = 1;
}
