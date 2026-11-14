// Compare request windows, never assign a guest render to an exact instant.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function compareTrial(trial, movieOffsetMs, guestSamples) {
    const sent = movieOffsetMs + trial.requestMoviePTS * 1000;
    const marginMs = 2; // Greater than one tick of the current 1/600 MOV time base.
    return {
        name: trial.name,
        guestSamples: guestSamples.length,
        unavailable: guestSamples.filter(row => !row.hash).length,
        guestDark: guestSamples.filter(row => row.state === 'dark').map(row => ({ ...row,
            sentAfterRequestMs: row.sent - sent, receivedAfterRequestMs: row.received - sent })),
        movieDark: trial.darkSamples.map(frame => ({ ...frame,
            overlappingGuestRequests: guestSamples.filter(row => row.sent <= sent + frame.afterRequestMs + marginMs &&
                row.received >= sent + frame.afterRequestMs - marginMs),
        })),
        repeatedMovieLuma: trial.repeats.filter(row => !row.dark && row.spanMs >= 150).map(row => {
            const start = movieOffsetMs + row.start * 1000;
            const end = movieOffsetMs + row.end * 1000;
            const contained = guestSamples.filter(sample => sample.hash && sample.identityStable && sample.targetPanel &&
                sample.sent >= start + marginMs && sample.received <= end - marginMs);
            return { ...row, containedGuestRequests: contained,
                distinctGuestLuma: new Set(contained.map(sample => sample.hash)).size };
        }),
    };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [root] = process.argv.slice(2);
    if (!root) throw Error('Usage: f5-source-report.mjs <paired recording evidence directory>');
    const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
    const alignment = read('movie-alignment.json');
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
        const samples = read(`motion/samples/${trial.name}/guest-samples.json`).map(sample => {
            const row = classified.find(row => row.trial === trial.name && row.sample_file === sample.file);
            if (sample.file && !/^[a-f0-9]{64}$/.test(row?.luma_sha256 ?? '')) throw Error('Missing guest image classification');
            const source = sample.metadata?.source, after = sample.metadata?.source_after;
            return { file: sample.file ?? null, sent: sample.sent, received: sample.received,
                state: row?.state ?? 'unavailable', hash: row?.luma_sha256 ?? null,
                panel: source?.name ?? null, displayID: source?.display_id ?? null,
                identityStable: sample.metadata?.available === true && Number.isInteger(source?.display_id) &&
                    source.display_id === after?.display_id && source.name === after?.name,
                targetPanel: source?.name === expected,
                reason: sample.metadata?.reason ?? sample.error ?? null };
        });
        const result = compareTrial(trial, alignment.movieZeroAfterSamplerOriginMs, samples);
        result.handoffVerdict = handoffs.get(trial.name) ?? 'unconfirmed';
        const context = read(`motion/samples/${trial.name}/action.json`);
        result.orientation = { requested: context.orientation, before: context.before?.degrees, after: context.after?.degrees,
            sampled: [...new Set(read(`motion/samples/${trial.name}/samples.json`).map(sample => sample.state?.degrees ?? null))] };
        return result;
    });
    console.log(JSON.stringify({
        scope: 'Guest request windows versus host MOV observations. Overlap is not simultaneous sampling. Native capture can affect rendering. Hashes compare frames only within each source.',
        trials: results,
    }, null, 2));
}
