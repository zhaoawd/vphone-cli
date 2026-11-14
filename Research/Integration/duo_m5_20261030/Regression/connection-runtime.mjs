// Runtime checks for a pinned build on a disposable Duo VM. The guest's
// script session resumes the proxy even if the host loses its connection.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const [socketArg, outputArg, expected, mode, group, stopCliArg] = process.argv.slice(2);
if (!socketArg || !outputArg || !/^[a-f0-9]{64}$/.test(expected ?? '') || !['orientation', 'slow'].includes(mode)
    || (group && (mode !== 'orientation' || !['short', 'long', 'portrait', 'stop'].includes(group)))
    || (group === 'stop') !== Boolean(stopCliArg)) {
    throw Error('Usage: connection-runtime.mjs <vphone.sock> <new output> <vphoned SHA-256> <orientation|slow> [short|long|portrait|stop [absolute vphone-cli]]');
}
const build = fs.realpathSync(fileURLToPath(new URL('../../../../.build', import.meta.url))) + path.sep;
const socket = fs.realpathSync(socketArg);
const output = path.join(fs.realpathSync(path.dirname(outputArg)), path.basename(outputArg));
const stopCli = stopCliArg && path.isAbsolute(stopCliArg) ? fs.realpathSync(stopCliArg) : null;
if (!socket.startsWith(build) || path.basename(socket) !== 'vphone.sock' || !fs.statSync(socket).isSocket() || !output.startsWith(build)) {
    throw Error('Expected a workspace acceptance socket and output directory');
}
if (group === 'stop' && (!stopCli?.startsWith(build) || path.basename(stopCli) !== 'vphone-cli')) {
    throw Error('Expected an absolute vphone-cli path under the workspace build directory');
}
fs.mkdirSync(output);
process.chdir(path.dirname(socket));
const save = (file, value) => fs.writeFileSync(path.join(output, file), JSON.stringify(value, null, 2) + '\n');
const now = () => performance.now();
const assert = (condition, message) => { if (!condition) throw Error(message); };
const request = (message, timeout = 5000) => new Promise((resolve, reject) => {
    const client = net.createConnection('./vphone.sock', () => client.write(JSON.stringify({ screen: false, ...message }) + '\n'));
    const chunks = [];
    client.setTimeout(timeout, () => client.destroy(Error('Host automation socket timed out')));
    client.on('error', reject).on('data', chunk => chunks.push(chunk)).on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks))); } catch (error) { reject(error); }
    });
});
const rpc = (method, params = {}, timeout) => request({ t: 'rpc', method, params }, timeout);
const checked = async (method, params) => {
    const reply = await rpc(method, params, method === 'screen.unlock' ? 35000 : undefined);
    assert(reply.ok, `${method}: ${reply.error}`);
    return reply.result;
};
const info = await checked('device.info');
assert(info.agent?.binary_hash === expected, 'Guest daemon does not match the pinned build');
save('device.json', info.agent);

if (mode === 'slow') {
    for (const delay of [2000, 125000]) {
        const sent = now();
        const reply = await rpc('script.eval', { source: `sleep(${delay}); 42`, timeout: delay / 1000 + 15 }, 145000);
        const elapsed = now() - sent;
        save(`slow-${delay}.json`, { elapsed, reply });
        if (delay === 2000) {
            assert(elapsed >= 1900 && elapsed < 10000 && reply.ok && reply.result?.ok && String(reply.result.result) === '42', 'Slow control request did not complete');
        } else {
            assert(elapsed >= 118000 && elapsed < 125000 && !reply.ok && reply.error === 'API protocol error: HTTP response timed out', 'Did not receive the expected VSOCK read timeout');
        }
        console.log(`${delay} ms delay: ${Math.round(elapsed)} ms, ${reply.error ?? 'success'}`);
    }
    const recovered = await checked('device.info');
    assert(recovered.agent?.pid === info.agent.pid && recovered.agent.binary_hash === expected, 'Guest daemon changed during slow request');
    save('recovered.json', recovered.agent);
} else {
    assert((await request({ t: 'display.geometry' })).result?.windowed, 'Windowed VM required');
    await checked('screen.unlock', { timeout: 30 });
    const read = async fn => { try { return await fn(); } catch (error) { return { error: String(error) }; } };
    const window = async () => (await request({ t: 'display.geometry' })).result?.view;
    async function waitForPose(label, degrees, hinge) {
        const deadline = now() + 6000;
        while (now() < deadline) {
            const orientation = await checked('display.orientation');
            const view = await window();
            const angle = orientation.fold_angle;
            if (orientation.degrees === degrees && view?.screen_orientation === degrees
                && Number.isFinite(angle) && (hinge === 'closed' ? angle <= 5 : angle >= 175)) return { label, orientation, view };
            await sleep(200);
        }
        throw Error(`${label}: guest and window did not reach the requested pose`);
    }
    const results = [];
    const cases = group === 'portrait' ? [['closed', 2400, 'cover-portrait'], ['open-flat', 2400, 'inner-portrait']]
        : group === 'stop' ? [['open-flat', 10500, 'inner-stop']]
            : [['closed', 2400, 'cover-short'], ['open-flat', 2400, 'inner-short'], ['closed', 10500, 'cover-long'], ['open-flat', 10500, 'inner-long']];
    for (const [hinge, pause, name] of cases) {
        if (group && !name.endsWith(`-${group}`)) continue;
        const startDegrees = group === 'portrait' ? 0 : 90;
        await checked('display.posture', { hinge });
        await sleep(1600);
        await checked('apps.launch', { bundle_id: 'com.apple.mobilesafari' });
        await sleep(1000);
        await checked('display.rotation', { orientation: startDegrees === 90 ? 'landscape-left' : 'portrait' });
        await sleep(1000);
        const orientation = await checked('display.orientation');
        assert(orientation.degrees === startDegrees && (hinge === 'closed' ? orientation.fold_angle <= 5 : orientation.fold_angle >= 175), `${name}: unexpected starting pose`);
        const geom = (await request({ t: 'display.geometry' })).result;
        assert(geom.view?.screen_orientation === startDegrees, `${name}: unexpected window orientation`);
        const agent = (await checked('device.info')).agent;
        const { processes } = await checked('processes.list', { filter: 'vphoned' });
        const worker = processes.find(row => row.pid === agent.pid && row.name === 'vphoned');
        const proxy = processes.find(row => row.pid === worker?.ppid && row.ppid === 1 && row.name === 'vphoned');
        assert(proxy && worker, `${name}: did not identify the worker and its launchd proxy`);
        // The guest-owned session runs independently of the worker. Stop the
        // proxy's restart loop, close the worker's VSOCK listener by exiting
        // it, then resume only that same proxy after a bounded interval.
        const signal = (pid, name) => `api('processes.kill',{pid:${pid},signal:'${name}',force:true})`;
        const source = `${signal(proxy.pid, 'STOP')}; try { ${signal(worker.pid, 'TERM')}; sleep(${pause}); } finally { ${signal(proxy.pid, 'CONT')}; }`;
        const t0 = now();
        const samples = [];
        const fault = read(() => rpc('script.eval', { source, timeout: 20 }, 5000));
        let stop;
        try {
            while (now() - t0 < pause + 6500) {
                const sent = now() - t0;
                const [guest, host] = await Promise.all([
                    read(() => rpc('display.orientation', {}, 1500)),
                    read(() => request({ t: 'display.geometry' }, 1500)),
                ]);
                const view = host.result?.view;
                samples.push({ sent, received: now() - t0, guest, window: view?.screen_orientation,
                    rotation: view?.view_rotation, bounds: view?.view_bounds, hostError: host.error });
                if (group === 'stop' && guest.error === 'guest not connected') {
                    assert(view?.screen_orientation === 90, 'Window lost landscape before stop');
                    const sent = now() - t0;
                    const machine = path.dirname(socket);
                    const result = await promisify(execFile)(stopCli, ['vm', 'stop', '-l', path.dirname(machine), path.basename(machine), '--timeout', '20']);
                    stop = { sent, received: now() - t0, ...result };
                    break;
                }
                await sleep(150);
            }
        } finally {
            save(`${name}.json`, { pause, hinge, orientation, geom, proxy: proxy.pid, worker: worker.pid, faultReply: await fault, samples, stop });
        }
        const disconnected = samples.find(s => s.guest.error === 'guest not connected');
        if (group === 'stop') {
            assert(disconnected && stop && /sending SIGINT/.test(stop.stdout) && !/force-killing/.test(stop.stdout)
                && stop.received - disconnected.received < 5000, 'VM did not stop during the hold without a forced kill');
            console.log('VM stopped during the orientation hold');
            continue;
        }
        const reconnected = disconnected && samples.find(s => s.sent > disconnected.received && s.guest.ok);
        const portrait = startDegrees !== 0 && disconnected && samples.find(s => s.sent > disconnected.received && s.window === 0);
        const fallback = portrait ? portrait.received - disconnected.received : null;
        const beforeDeadline = disconnected && samples.filter(s => s.received >= disconnected.received &&
            s.received < Math.min(disconnected.received + 4000, reconnected?.received ?? Infinity));
        const recovered = await checked('device.info');
        const valid = Boolean(disconnected && reconnected && recovered.agent.pid !== agent.pid && recovered.agent.binary_hash === expected
            && beforeDeadline.length > 0 && beforeDeadline.every(s => s.window === startDegrees)
            && (pause < 5000 ? reconnected.received - disconnected.received < 5000 && samples.every(s => s.window === startDegrees)
                : portrait && fallback >= 4000 && fallback <= 6000 && portrait.received < reconnected.received)
            && samples.at(-1).window === startDegrees);
        results.push({ name, valid, disconnected: disconnected?.received, reconnected: reconnected?.received, fallback });
        save('summary.json', results);
        console.log(JSON.stringify(results.at(-1)));
        if (group === 'portrait' && valid) {
            const steps = [];
            await checked('display.rotation', { orientation: 'landscape-left' });
            steps.push(await waitForPose('rotate after reconnect', 90, hinge));
            await checked('display.rotation', { orientation: 'portrait' });
            steps.push(await waitForPose('return to portrait', 0, hinge));
            const next = hinge === 'closed' ? 'open-flat' : 'closed';
            await checked('display.posture', { hinge: next, orientation: next === 'closed' ? 1 : 3 });
            steps.push(await waitForPose('change active panel', 0, next));
            save(`${name}-after-reconnect.json`, steps);
        }
    }
    if (results.some(result => !result.valid)) process.exitCode = 1;
}
