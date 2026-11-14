// Observe the three Duo issues with an explicitly pinned daemon.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const [socketArg, outputArg, expectedAgent = '446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b'] = process.argv.slice(2);
if (!/^[a-f0-9]{64}$/.test(expectedAgent)) throw Error('Expected daemon SHA-256 required');
const root = fs.realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const socket = fs.realpathSync(socketArg), output = path.resolve(outputArg);
if (!socket.startsWith(root + '/.build/') || path.basename(socket) !== 'vphone.sock' || !output.startsWith(root + '/.build/')) throw Error('Workspace disposable VM required');
fs.mkdirSync(output);
process.chdir(path.dirname(socket));
const origin = process.hrtime.bigint();
const now = () => Number(process.hrtime.bigint() - origin) / 1e6;
const save = (file, data) => fs.writeFileSync(path.join(output, file), JSON.stringify(data, null, 2) + '\n');
const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    const chunks = [];
    const client = net.createConnection('./vphone.sock', () => client.write(JSON.stringify({ t: 'rpc', method, params, screen: false, delay: 0 }) + '\n'));
    client.setTimeout(30000, () => client.destroy(Error('RPC timeout')));
    client.on('data', chunk => chunks.push(chunk));
    client.on('error', reject);
    client.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks))); } catch (e) { reject(e); } });
});
const checked = async (method, params) => {
    const reply = await rpc(method, params);
    if (!reply.ok) throw Error(`${method}: ${reply.error}`);
    return reply.result;
};
save('clock.json', { host_uptime_origin_ns: origin.toString(), epoch_at_origin_ms: Date.now() - now() });
const device = await checked('device.info');
if (device.agent.binary_hash !== expectedAgent) throw Error('Unpinned daemon');
save('device.json', device);
save('environment-before.json', await checked('environment.status'));
await checked('screen.unlock', { timeout: 30 });
const captures = [];
for (const hinge of ['closed', 'open-flat', 'closed', 'open-flat']) {
    const index = captures.length;
    await checked('display.posture', { hinge });
    await checked('display.rotation', { orientation: 'portrait' });
    await checked('input.button', { name: 'home' });
    await sleep(1800);
    const layout = await checked('display.layout');
    const orientation = await checked('display.orientation');
    const foreground = await checked('apps.foreground');
    const tree = await checked('ui.tree');
    const points = tree.elements.filter(e => e.identifier === 'Settings' || e.identifier === 'Camera').slice(0, 2)
        .map(e => ({ identifier: e.identifier, x: e.x, y: e.y }));
    if (!points.length) points.push({ identifier: 'center', x: 200, y: 300 });
    const hits = [];
    for (const point of points) hits.push({ point, response: await rpc('ui.element_at', { x: point.x, y: point.y }) });
    const capture = await rpc('display.capture_active');
    const { base64, ...metadata } = capture.result ?? {};
    if (base64) fs.writeFileSync(path.join(output, `display-${index}.png`), Buffer.from(base64, 'base64'));
    captures.push({ index, hinge, layout, orientation, foreground, points, hits, capture: { ok: capture.ok, metadata, error: capture.error } });
    save(`display-${index}.json`, captures.at(-1));
}

async function lockSample() {
    const sent = now();
    const [snapshot, blanked, panel] = await Promise.all([
        checked('device.snapshot'), checked('notify.state', { name: 'com.apple.springboard.hasBlankedScreen' }),
        checked('notify.state', { name: 'com.vphone.folddisplay.panel-dark' }),
    ]);
    return { sent, received: now(), lock: snapshot.lock, blanked: blanked.state, panel: panel.state };
}
const alwaysOn = s => s.lock?.locked && s.lock.screen_off && s.blanked === 1 && s.panel === 1;
const aod = [];
for (const target of ['closed-control', 'open', 'closed', 'open', 'closed']) {
    const initialHinge = target === 'closed' ? 'open' : 'closed';
    await checked('screen.unlock', { timeout: 30 });
    await checked('display.posture', { hinge: initialHinge });
    // Native postflight includes delayed display power changes after the swap.
    // Settle the fixture before locking; the measured fold window is unchanged.
    await sleep(4500);
    await checked('input.button', { name: 'power' });
    await sleep(2200);
    let before = await lockSample();
    let readinessPolls = 0;
    while (!alwaysOn(before) && readinessPolls < 20) {
        await sleep(100); before = await lockSample(); readinessPolls++;
    }
    const setupAttempts = [before];
    // A lock request during the previous pose's delayed activation may leave
    // the device locked but lit. Establish the same AOD precondition again
    // without sending another pose. Never retry a measured fold.
    while (!alwaysOn(before) && before.blanked === 0 && before.panel === 1 && setupAttempts.length < 3) {
        await sleep(1000);
        await checked('input.button', { name: 'power' });
        await sleep(2200);
        before = await lockSample();
        setupAttempts.push(before);
    }
    const row = { target, before, readinessPolls, setupAttempts, enteredAlwaysOn: alwaysOn(before), samples: [] };
    if (!row.enteredAlwaysOn) { aod.push(row); save('aod.json', aod); continue; }
    let stop = false;
    const sampling = (async () => { while (!stop) { row.samples.push(await lockSample()); await sleep(35); } })();
    await sleep(150);
    row.sent = now();
    row.response = target === 'closed-control' ? null : await rpc('display.posture', { hinge: target });
    row.received = now();
    await sleep(1800);
    stop = true;
    await sampling;
    row.after = await lockSample();
    aod.push(row);
    save('aod.json', aod);
}
save('fold-log.json', await checked('files.read', { path: '/var/mobile/Library/Caches/vphone-folddisplay.log', limit: 4194304 }));
save('environment-after.json', await checked('environment.status'));
save('summary.json', { displays: captures.map(s => ({ index: s.index, hinge: s.hinge,
    captureAvailable: s.capture.metadata.available, hits: s.hits.map(h => ({ identifier: h.point.identifier, ok: h.response.ok, error: h.response.error })) })),
    aod: aod.map(s => ({ target: s.target, enteredAlwaysOn: s.enteredAlwaysOn,
        remainedAlwaysOn: s.after ? alwaysOn(s.after) && s.samples.length > 0 && s.samples.every(alwaysOn) : null })) });
console.log(JSON.stringify(JSON.parse(fs.readFileSync(path.join(output, 'summary.json'))), null, 2));
