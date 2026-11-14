// Replay an actual recording. A confirmed fold with any near-black sample
// fails this diagnostic check; repeated luma spans are reported separately.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { alignMovie } from './f5-mov-align.mjs';

const [root, selected] = process.argv.slice(2);
if (!root || (selected && !/^\d+-\d+-(open|closed)$/.test(selected))) {
    throw Error('Usage: f5-presentation-check.mjs <recording evidence directory> [trial]');
}
const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const analyzer = fileURLToPath(new URL('./f5-mov-timing.mjs', import.meta.url));
const decoded = spawnSync(process.execPath, [analyzer, path.join(root, 'recording.mov')],
    { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
if (decoded.status !== 0) throw Error(decoded.stderr || decoded.error || 'Movie decode failed');
const timing = JSON.parse(decoded.stdout);
const sampleRoot = path.join(root, 'motion/samples');
const trials = fs.readdirSync(sampleRoot).filter(name => /^\d+-\d+-(open|closed)$/.test(name))
    .filter(name => !selected || name === selected)
    .map(name => ({ name, action: read(`motion/samples/${name}/action.json`).action,
        samples: read(`motion/samples/${name}/samples.json`) }));
const handoffLines = fs.readFileSync(path.join(root, 'motion/handoff.tsv'), 'utf8').trim().split('\n');
const header = handoffLines.shift().split('\t');
const verdicts = new Map(handoffLines.map(line => {
    const columns = line.split('\t');
    return [columns[header.indexOf('trial')], columns[header.indexOf('verdict')]];
}));
if (!trials.length || trials.some(trial => verdicts.get(trial.name) !== 'confirmed')) {
    throw Error('Every selected trial must have a confirmed panel handoff');
}
const aligned = alignMovie(timing, fs.readFileSync(path.join(root, 'boot.log'), 'utf8'),
    read('motion/samples/clock.json'), trials);
const results = aligned.trials.map(trial => {
    const context = read(`motion/samples/${trial.name}/action.json`);
    const sampled = [...new Set(read(`motion/samples/${trial.name}/samples.json`).map(sample => sample.state?.degrees ?? null))];
    return { name: trial.name, darkSamples: trial.darkSamples,
        orientation: { requested: context.orientation, before: context.before?.degrees, after: context.after?.degrees, sampled },
        longestNonblack: trial.repeats.filter(row => !row.dark).sort((a, b) => b.spanMs - a.spanMs)[0] ?? null };
});
const ok = results.every(trial => trial.darkSamples.length === 0);
console.log(JSON.stringify({ ok, criterion: 'No near-black MOV samples in confirmed fold observation windows',
    trials: results }, null, 2));
if (!ok) process.exitCode = 1;
