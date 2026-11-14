// Bound the blanked transition from consecutive host RPC samples. Compare
// with the guest log only if both clocks are aligned closely enough.
import fs from 'node:fs';
import path from 'node:path';

const [root] = process.argv.slice(2);
if (!root) throw Error('Usage: f5-aod-timeline.mjs <f5-clock evidence directory>');
const read = (file) => JSON.parse(fs.readFileSync(path.join(root, file)));
const origin = read('clock.json').epoch_ms_at_monotonic_zero;
const events = fs.readFileSync(path.join(root, 'folddisplay.log'), 'utf8').split('\n')
    .map(line => line.match(/^(\d+\.\d{3}) inner display: (.*)$/))
    .filter(Boolean).map(([, time, text]) => ({ time: Number(time) * 1000 - origin, text }));
console.log('trial\tblanked_lower_ms\tblanked_upper_ms\towner_ms\tarriving_display_on_request_ms');
for (const trial of fs.readdirSync(root).filter(name => /^\d+-\d+-(open|closed)$/.test(name)).sort()) {
    if (!fs.existsSync(path.join(root, trial, 'action.json'))) continue;
    const { action } = read(`${trial}/action.json`);
    const opening = trial.endsWith('-open');
    const samples = read(`${trial}/aod-notify.json`);
    const first = samples.findIndex(sample => sample.received >= action.sent && sample.blanked === 0);
    const previous = first >= 0 ? samples.slice(0, first).findLast(sample => sample.blanked === 1) : null;
    const near = events.filter(event => event.time >= action.sent - 2 && event.time < action.sent + 2400);
    const owner = near.find(event => event.text === `panel owned by the ${opening ? 'inner display' : 'cover'}`);
    const power = near.find(event => (!owner || event.time >= owner.time) && /^display \d+ wants state [1-9]\d*$/.test(event.text)
        && (opening ? !event.text.startsWith('display 1 ') : event.text.startsWith('display 1 ')));
    const relative = t => Number.isFinite(t) ? Math.round(t - action.sent) : '-';
    console.log([trial, relative(previous?.sent), relative(samples[first]?.received), relative(owner?.time), relative(power?.time)].join('\t'));
}
