// Match each f5-clock transition with the guest FoldDisplay events around
// its fold request: whether the panel actually changed hands, and when the
// power handoff and the last-frame hold started and ended (ms after the
// request). Needs clock.json (f5-clock.mjs with an epoch origin) and the
// guest log read after the run.
import fs from 'node:fs';
import path from 'node:path';

const [root, logPath, mode] = process.argv.slice(2);
if (!root || !logPath || (mode && mode !== '--require-handoff')) {
    throw Error('Usage: f5-handoff-report.mjs <f5-clock output> <folddisplay.log> [--require-handoff]');
}
const { epoch_ms_at_monotonic_zero: origin, sweep_s: sweep = 0 } = JSON.parse(fs.readFileSync(path.join(root, 'clock.json')));
const events = fs.readFileSync(logPath, 'utf8').split('\n')
    .map(line => line.match(/^(\d+\.\d{3}) inner display: (.*)$/))
    .filter(Boolean).map(([, t, text]) => ({ t: Number(t) * 1000, text }));
const trials = fs.readdirSync(root).filter(name => /^\d+-\d+-(open|closed)$/.test(name))
    .map(name => {
        const file = path.join(root, name, 'action.json');
        return { name, action: fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)).action : null };
    }).sort((a, b) => (a.action?.sent ?? Infinity) - (b.action?.sent ?? Infinity));
let missing = !trials.length;
console.log(['trial', 'owner', 'hold_on', 'hold_off', 'hold_reason', 'handoff', 'events', 'hold_ms', 'expected_owner', 'capture_before', 'capture_after', 'verdict'].join('\t'));
for (const [index, { name, action }] of trials.entries()) {
    if (!action) { missing = true; continue; }
    const sent = origin + action.sent;
    const end = Math.min(sent + 2500 + sweep * 1000, origin + (trials[index + 1]?.action?.sent ?? Infinity));
    const near = events.filter(e => e.t >= sent - 2 && e.t < end);
    const at = e => e ? Math.round(e.t - sent) : '-';
    const expected = name.endsWith('-open') ? 'inner display' : 'cover';
    const opposite = name.endsWith('-open') ? 'cover' : 'inner display';
    const owner = near.findLast(e => e.text.startsWith('panel owned by the '));
    const readPanel = when => {
        const file = path.join(root, name, `panel-${when}.json`);
        return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)).panel ?? 'unavailable' : '-';
    };
    const before = readPanel('before');
    const after = readPanel('after');
    const logMatches = owner?.text === `panel owned by the ${expected}`;
    const captureMatches = before === opposite && after === expected;
    const hasCaptures = before !== '-' || after !== '-';
    const valid = action.response.ok && logMatches && (!hasCaptures || captureMatches);
    if (!valid) missing = true;
    const verdict = valid ? 'confirmed' : captureMatches ? 'log_mismatch' : 'unconfirmed';
    const on = near.find(e => e.text.startsWith('hold on'));
    const off = near.find(e => e.text.startsWith('hold off') && (!on || e.t >= on.t));
    const handoff = near.find(e => e.text.startsWith('handoff released'));
    console.log([name, owner ? `${owner.text.replace('panel owned by the ', '')}@${at(owner)}` : 'none',
        at(on), at(off), off ? off.text.match(/\((.*)\)/)?.[1] ?? '-' : '-',
        handoff ? `${handoff.text.match(/\((.*)\)/)?.[1]}@${at(handoff)}` : '-', near.length,
        off?.text.match(/ after (\d+) ms$/)?.[1] ?? '-', expected, before, after, verdict].join('\t'));
}
if (missing && mode === '--require-handoff') process.exitCode = 1;
