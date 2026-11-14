// Measure the first touch delivered to a Safari test page after a Duo fold.
// The host timestamps both the fold request and the page's acknowledgement.
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const [socketArg, outArg, expected, bind] = process.argv.slice(2);
if (!socketArg || !outArg || !/^[a-f0-9]{64}$/.test(expected ?? '') || net.isIP(bind ?? '') !== 4) {
    throw Error('Usage: f5-first-input.mjs <vphone.sock> <new output> <vphoned SHA-256> <host address on guest network>');
}
const build = fs.realpathSync(fileURLToPath(new URL('../../../../.build', import.meta.url))) + path.sep;
const socket = fs.realpathSync(socketArg);
const out = path.join(fs.realpathSync(path.dirname(outArg)), path.basename(outArg));
if (!socket.startsWith(build) || path.basename(socket) !== 'vphone.sock' || !fs.statSync(socket).isSocket() || !out.startsWith(build)) {
    throw Error('Expected workspace test socket and output directory');
}
fs.mkdirSync(out);
process.chdir(path.dirname(socket));
const started = performance.now();
const now = () => performance.now() - started;
const origin = Date.now() - now();
const save = (file, value) => fs.writeFileSync(path.join(out, file), JSON.stringify(value, null, 2) + '\n');
const request = message => new Promise((resolve, reject) => {
    const client = net.createConnection('./vphone.sock', () => client.write(JSON.stringify({ screen: false, ...message }) + '\n'));
    const chunks = [];
    client.setTimeout(5000, () => client.destroy(Error('Host socket timed out')));
    client.on('error', reject).on('data', chunk => chunks.push(chunk)).on('end', () => {
        try {
            const response = JSON.parse(Buffer.concat(chunks));
            if (!response.ok) throw Error(response.error);
            resolve(response.result);
        } catch (error) { reject(error); }
    });
});
const rpc = (method, params = {}) => request({ t: 'rpc', method, params });
const { agent } = await rpc('device.info');
if (agent?.binary_hash !== expected) throw Error('Guest daemon does not match the pinned build');
if (!(await request({ t: 'display.geometry' }))?.windowed) throw Error('Windowed VM required');

const route = '/' + randomUUID();
const events = [];
let ready = false;
const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === route) {
        res.setHeader('Content-Type', 'text/html; charset=utf-8');
        res.setHeader('Cache-Control', 'no-store');
        res.end(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>html,body{margin:0;height:100%;background:#163654;touch-action:none;color:white;font:24px sans-serif}</style>
<div id="label">Duo input probe</div><script>
let seq=0;
document.addEventListener('touchstart',e=>{
  const t=e.changedTouches[0];
  document.querySelector('#label').textContent='Touch '+(++seq);
  fetch(location.pathname+'/touch',{method:'POST',body:JSON.stringify({seq,x:t.clientX,y:t.clientY,w:innerWidth,h:innerHeight})});
  e.preventDefault();
},{passive:false});
fetch(location.pathname+'/ready',{method:'POST'});
</script>`);
    } else if (req.method === 'POST' && req.url === route + '/ready') {
        ready = true;
        res.end('ok');
    } else if (req.method === 'POST' && req.url === route + '/touch') {
        let body = '';
        req.on('data', chunk => { body += chunk; if (body.length > 512) req.destroy(); });
        req.on('end', () => {
            try {
                const { seq, x, y, w, h } = JSON.parse(body);
                if (![seq, x, y, w, h].every(Number.isFinite) || seq <= 0 || x <= 0 || x >= w || y <= 0 || y >= h) throw Error();
                events.push({ received: now(), seq, x, y, w, h });
                res.end('ok');
            } catch { res.writeHead(400).end(); }
        });
    } else { res.writeHead(404).end(); }
});

async function waitFor(predicate, timeout) {
    const end = now() + timeout;
    while (now() < end) {
        const value = predicate();
        if (value) return value;
        await sleep(10);
    }
    return null;
}
const posture = hinge => ({ hinge, orientation: hinge === 'open' ? 3 : 1 });
const safari = async () => {
    const state = await rpc('apps.foreground');
    if (state?.bundle_id !== 'com.apple.mobilesafari' || state.verified !== true) throw Error('Safari is not the verified foreground app');
    return state;
};
await new Promise((resolve, reject) => server.once('error', reject).listen(0, bind, resolve));
const trials = [];
try {
    await rpc('screen.unlock', { timeout: 30 });
    await rpc('display.posture', posture('closed'));
    await sleep(2000);
    await rpc('apps.open_url', { url: `http://${bind}:${server.address().port}${route}` });
    if (!await waitFor(() => ready, 15000)) throw Error('Safari test page did not connect');
    const { pid } = await safari();
    const { screenshot_pixels: pixels } = await request({ t: 'display.geometry' });
    const middle = Math.min(...pixels);
    if (!(middle > 0)) throw Error('Missing screenshot geometry');
    const tap = () => request({ t: 'tap', x: middle * 0.5, y: middle * 0.5 });
    const baselineSent = now();
    await tap();
    const baseline = await waitFor(() => events.find(e => e.received > baselineSent), 1500);
    if (!baseline) throw Error('Test page did not receive a tap before folding');
    save('baseline.json', { sent: baselineSent, baseline, pid });
    await sleep(600);

    for (let i = 0; i < 6; i++) {
        const hinge = i % 2 ? 'closed' : 'open';
        const index = events.length;
        const trial = { hinge, sent: now(), taps: [] };
        trials.push(trial);
        const fold = rpc('display.posture', posture(hinge)).then(result => {
            trial.reply = { at: now(), result };
        }, error => { trial.reply = { at: now(), error: String(error) }; });
        // Send the first tap with the fold in progress; space attempts so the
        // window's touch-up and the page acknowledgement can arrive.
        await sleep(40);
        while (now() - trial.sent < 3000 && events.length === index) {
            const attempt = { sent: now() };
            trial.taps.push(attempt);
            try { await tap(); } catch (error) { attempt.error = String(error); }
            attempt.replied = now();
            await waitFor(() => events[index], 140);
        }
        trial.first = events[index] ?? null;
        await fold;
        await sleep(2000);
        trial.orientation = await rpc('display.orientation');
        trial.foreground = await safari();
        const angle = trial.orientation.fold_angle;
        trial.valid = trial.reply.result?.hinge_hid?.applied === true && trial.foreground.pid === pid && Number.isFinite(angle)
            && (hinge === 'open' ? angle >= 175 : angle <= 5);
        save('trials.json', trials);
        const offset = trial.first ? `${Math.round(trial.first.received - trial.sent)} ms` : 'no touch acknowledgement';
        console.log(`${i + 1} ${hinge}: ${offset} (${trial.taps.length} attempts)`);
    }
    const log = await rpc('files.read', { path: '/var/mobile/Library/Caches/vphone-folddisplay.log', limit: 4194304 });
    if (log?.truncated !== false || log.encoding !== 'utf8') throw Error('Missing complete FoldDisplay log');
    const owners = [...log.content.matchAll(/^(\d+\.\d{3}) inner display: panel owned by the (inner display|cover)$/gm)]
        .map(([, seconds, panel]) => ({ at: Number(seconds) * 1000 - origin, panel }));
    for (const [i, trial] of trials.entries()) {
        const end = Math.min(trial.sent + 2500, trials[i + 1]?.sent ?? Infinity);
        trial.owner = owners.findLast(event => event.at >= trial.sent - 2 && event.at < end) ?? null;
        trial.valid &&= trial.owner?.panel === (trial.hinge === 'open' ? 'inner display' : 'cover');
    }
    if (trials.some(trial => !trial.valid || !trial.first)) process.exitCode = 1;
} finally {
    server.closeAllConnections();
    server.close();
    save('events.json', events);
    save('trials.json', trials);
    save('clock.json', { epoch_ms_at_monotonic_zero: origin });
}
