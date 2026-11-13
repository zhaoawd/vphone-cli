// Match each f5-clock transition with the guest FoldDisplay events around
// its fold request: whether the panel actually changed hands, and when the
// power handoff and the last-frame hold started and ended (ms after the
// request). Needs clock.json (f5-clock.mjs with an epoch origin) and the
// guest log read after the run.
import fs from 'node:fs';
import path from 'node:path';

const [root, logPath] = process.argv.slice(2);
if (!root || !logPath) throw Error('Usage: f5-handoff-report.mjs <f5-clock output> <folddisplay.log>');
const { epoch_ms_at_monotonic_zero: origin } = JSON.parse(fs.readFileSync(path.join(root, 'clock.json')));
const events = fs.readFileSync(logPath, 'utf8').split('\n')
    .map(line => line.match(/^(\d+\.\d{3}) inner display: (.*)$/))
    .filter(Boolean).map(([, t, text]) => ({ t: Number(t) * 1000, text }));
const trials = fs.readdirSync(root).filter(name => /^\d+-\d+-(open|closed)$/.test(name)).sort((a, b) => {
    const [, x1, h1] = a.match(/^\d+-(\d+)-(\w+)$/), [, x2, h2] = b.match(/^\d+-(\d+)-(\w+)$/);
    return x1 - x2 || (h1 === 'open' ? -1 : 1) - (h2 === 'open' ? -1 : 1);
});
console.log(['trial', 'owner', 'hold_on', 'hold_off', 'hold_reason', 'handoff', 'events'].join('\t'));
for (const name of trials) {
    const { action } = JSON.parse(fs.readFileSync(path.join(root, name, 'action.json')));
    const sent = origin + action.sent;
    const near = events.filter(e => e.t >= sent - 100 && e.t <= sent + 2500);
    const at = e => e ? Math.round(e.t - sent) : '-';
    const owner = near.find(e => e.text.startsWith('panel owned by'));
    const on = near.find(e => e.text.startsWith('hold on'));
    const off = near.find(e => e.text.startsWith('hold off'));
    const handoff = near.find(e => e.text.startsWith('handoff released'));
    console.log([name, owner ? `${owner.text.replace('panel owned by the ', '')}@${at(owner)}` : 'none',
        at(on), at(off), off ? off.text.match(/\((.*)\)/)?.[1] ?? '-' : '-',
        handoff ? `${handoff.text.match(/\((.*)\)/)?.[1]}@${at(handoff)}` : '-', near.length].join('\t'));
}
