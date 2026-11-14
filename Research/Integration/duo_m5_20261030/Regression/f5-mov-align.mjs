// Align MOV observations with host request windows. Overlap establishes timing,
// not the cause of a repeated image; panel handoff needs its separate report.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function alignMovie(timing, log, clock, trials) {
    const origins = [...log.matchAll(/^\[record\] first frame - uptime_ns=(\d+) file=(.+)$/gm)];
    if (origins.length !== 1) throw Error('Expected exactly one recording origin in the VM log');
    if (!/^\d+$/.test(clock.host_uptime_ns_at_monotonic_zero ?? '')) {
        throw Error('Missing host monotonic origin; wall clock alignment is insufficient');
    }
    const offsetMs = Number(BigInt(origins[0][1]) - BigInt(clock.host_uptime_ns_at_monotonic_zero)) / 1e6;
    const times = timing.samples?.map(frame => frame.pts);
    if (!times || times.length < 2 || times.some((t, i) => !Number.isFinite(t) || (i && t <= times[i - 1])) ||
        !Array.isArray(timing.repeats) || !trials.length) throw Error('Invalid movie timing or missing trials');
    const movieStart = offsetMs + times[0] * 1000;
    const movieEnd = offsetMs + times.at(-1) * 1000;
    const aligned = trials.map(({ name, action, samples }) => {
        const sent = action?.sent;
        const received = action?.received;
        const end = samples?.at(-1)?.received;
        if (![sent, received, end].every(Number.isFinite) || received < sent || end < received ||
            action.response?.ok !== true || sent < movieStart || end > movieEnd) {
            throw Error(`Recording does not cover a successful request and observation window: ${name}`);
        }
        const repeats = timing.repeats.filter(row => offsetMs + row.start * 1000 < end &&
            offsetMs + row.end * 1000 > sent).map(row => ({ ...row,
            startAfterRequestMs: offsetMs + row.start * 1000 - sent,
            endAfterRequestMs: offsetMs + row.end * 1000 - sent,
        }));
        return { name, requestMoviePTS: (sent - offsetMs) / 1000,
            responseAfterRequestMs: received - sent, observationEndAfterRequestMs: end - sent,
            darkSamples: timing.samples.filter(frame => frame.dark && offsetMs + frame.pts * 1000 >= sent &&
                offsetMs + frame.pts * 1000 <= end).map(frame => ({ moviePTS: frame.pts,
                afterRequestMs: offsetMs + frame.pts * 1000 - sent })),
            repeats };
    });
    return { recording: origins[0][2], movieZeroAfterSamplerOriginMs: offsetMs,
        clock: 'DispatchTime.uptimeNanoseconds / process.hrtime.bigint on the same macOS boot',
        scope: 'Repeated downscaled luma observations overlapping host request windows; no causal attribution or guest frame timestamps',
        trials: aligned };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [timingFile, logFile, root] = process.argv.slice(2);
    if (!root) throw Error('Usage: f5-mov-align.mjs <movie-timing.json> <single-recording VM log> <f5-clock output>');
    const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
    const trials = fs.readdirSync(root).filter(name => /^\d+-\d+-(open|closed)$/.test(name)).sort()
        .map(name => ({ name, action: read(path.join(root, name, 'action.json')).action,
            samples: read(path.join(root, name, 'samples.json')) }));
    console.log(JSON.stringify(alignMovie(read(timingFile), fs.readFileSync(logFile, 'utf8'),
        read(path.join(root, 'clock.json')), trials), null, 2));
}
