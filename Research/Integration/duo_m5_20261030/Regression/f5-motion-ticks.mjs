// Report page execution separately from presentation image changes.
import fs from 'node:fs';
import path from 'node:path';

const [root] = process.argv.slice(2);
if (!root) throw Error('Usage: f5-motion-ticks.mjs <f5-motion evidence directory>');
const sampleRoot = path.join(root, 'samples');
const read = file => JSON.parse(fs.readFileSync(path.join(sampleRoot, file)));
const origin = read('clock.json').epoch_ms_at_monotonic_zero;
const ticks = fs.readFileSync(path.join(root, 'ticks.tsv'), 'utf8').trim().split('\n')
    .map(line => line.split('\t').map(Number));
if (ticks.length < 20 || ticks.some(([time, frame]) => !Number.isFinite(time) || !Number.isInteger(frame))) {
    throw Error('Missing or invalid animation ticks');
}
console.log('trial\tbaseline_tick_count\tfirst_tick_after_request_ms\tmax_tick_gap_ms');
for (const name of fs.readdirSync(sampleRoot).filter(name => /^\d+-\d+-(open|closed)$/.test(name)).sort()) {
    const { action } = read(`${name}/action.json`);
    const sent = origin + action.sent;
    const baseline = ticks.filter(([t]) => t >= sent - 1000 && t < sent);
    const window = ticks.filter(([t]) => t >= sent - 1000 && t <= sent + 1800);
    const post = window.find(([t]) => t >= sent);
    const maxGap = window.length > 1 ? Math.max(...window.slice(1).map(([t], i) => t - window[i][0])) : null;
    console.log([name, baseline.length, post ? Math.round(post[0] - sent) : '-', maxGap ?? '-'].join('\t'));
    if (baseline.length < 3 || !post) process.exitCode = 1;
}
