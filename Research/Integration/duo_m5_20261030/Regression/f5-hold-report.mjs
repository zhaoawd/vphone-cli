import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function clockOffset(samples) {
    if (!samples.length || new Set(samples.map(row => row.boot_session_uuid)).size !== 1 ||
        !samples[0].boot_session_uuid) throw Error('Missing or changed guest boot session');
    let lower = -Infinity, upper = Infinity;
    for (const row of samples) {
        if (![row.sent, row.received, row.guest_uptime_ms].every(Number.isFinite) || row.received < row.sent) throw Error('Invalid clock sample');
        lower = Math.max(lower, row.sent - row.guest_uptime_ms);
        upper = Math.min(upper, row.received - row.guest_uptime_ms);
    }
    if (lower > upper) throw Error('Guest/host clock offsets are inconsistent; do not align these events');
    return { lower, upper, uncertaintyMs: upper - lower };
}

export function darkPhase(point, on, off, tickMs = 1000 / 600) {
    if (!on || !off) return 'missing_hold_boundary';
    if (point + tickMs < on.lower) return 'before_commit_request';
    if (point - tickMs > off.upper) return 'after_release_request';
    if (point - tickMs > on.upper && point + tickMs < off.lower) return 'between_commit_and_release_requests';
    return 'boundary_uncertain';
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [root] = process.argv.slice(2);
    if (!root) throw Error('Usage: f5-hold-report.mjs <instrumented recording evidence>');
    const read = name => JSON.parse(fs.readFileSync(path.join(root, name), 'utf8'));
    const alignment = read('movie-alignment.json');
    const handoffRows = fs.readFileSync(path.join(root, 'motion/handoff.tsv'), 'utf8').trim().split('\n');
    const handoffColumns = handoffRows.shift().split('\t');
    const handoffs = new Map(handoffRows.map(line => {
        const cells = line.split('\t');
        return [cells[handoffColumns.indexOf('trial')], cells[handoffColumns.indexOf('verdict')]];
    }));
    const traces = fs.readFileSync(path.join(root, 'motion/folddisplay.log'), 'utf8').split('\n')
        .map(line => line.match(/\[DEBUG-f5-hold\] (\{.*\})$/)?.[1]).filter(Boolean).map(text => JSON.parse(text));
    if (!traces.length) throw Error('No enabled hold diagnostics were recorded');
    const trials = alignment.trials.map(trial => {
        const prefix = `motion/samples/${trial.name}/`;
        const before = read(prefix + 'clock-before.json'), after = read(prefix + 'clock-after.json');
        const offset = clockOffset([...before, ...after]);
        const sent = alignment.movieZeroAfterSamplerOriginMs + trial.requestMoviePTS * 1000;
        const events = traces.filter(row => row.boot_session_uuid === before[0].boot_session_uuid).map(row => ({ ...row, host: {
            lower: row.guest_uptime_before * 1000 + offset.lower,
            upper: row.guest_uptime_after * 1000 + offset.upper,
        } })).filter(row => row.host.upper >= before[0].sent && row.host.lower <= after.at(-1).received)
            .map(row => ({ ...row, afterRequestMs: { lower: row.host.lower - sent, upper: row.host.upper - sent } }));
        const on = events.find(row => row.event === 'hold_on_commit');
        const off = events.find(row => row.event === 'hold_off_request' && row.pid === on?.pid && row.generation === on?.generation);
        const source = events.find(row => row.event === 'hold_source' && row.pid === on?.pid && row.generation === on?.generation);
        return { name: trial.name, handoffVerdict: handoffs.get(trial.name) ?? 'unconfirmed',
            clockOffset: offset, holdSource: source ?? null, events,
            darkSamples: trial.darkSamples.map(frame => ({ ...frame,
                phase: darkPhase(sent + frame.afterRequestMs, on?.host, off?.host) })) };
    });
    console.log(JSON.stringify({
        scope: '8x8 source grid and CPU-side layer commit/release requests; no proof of scanout visibility. Alignment requires a constant guest/host uptime offset consistent with all bracketing samples. MOV boundaries include one 1/600-second tick of uncertainty.',
        trials,
    }, null, 2));
}
