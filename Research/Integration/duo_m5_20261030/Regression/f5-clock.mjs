// Sample the host's presentation image and fold RPCs on one monotonic clock.
// Run only on a disposable, windowed VM. The probe sends Home, rotation and
// posture commands and saves screenshots of the guest Home Screen.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const root = fs.realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const [socketArg, outputArg, expected, ...options] = process.argv.slice(2);
const lockRotation = options.includes('--lock-rotation');
const holdInterface = options.includes('--match-panel-orientation');
const guestOption = options.find(x => x.startsWith('--guest='));
const guestCapture = guestOption?.slice('--guest='.length);
const checkPanel = options.includes('--check-panel');
const guestClock = options.includes('--guest-clock');
// --settle=<ms> waits after each fold, so SpringBoard does not merge folds
// made faster than its content mode transitions finish.
const settleOption = options.find(x => x.startsWith('--settle='));
const settle = settleOption ? Number(settleOption.slice('--settle='.length)) : 0;
const observeOption = options.find(x => x.startsWith('--observe='));
// --app=<bundle id> launches the app after setting the initial pose of each block.
const appOption = options.find(x => x.startsWith('--app='));
const app = appOption?.slice('--app='.length);
const pageOption = options.find(x => x.startsWith('--page='));
const page = pageOption?.slice('--page='.length);
// --sweep=<seconds> folds through `position` (a continuous sweep, the path
// DeviceHub's fold controls take) instead of setting the hinge at once.
const sweepOption = options.find(x => x.startsWith('--sweep='));
const sweep = sweepOption ? Number(sweepOption.slice('--sweep='.length)) : 0;
const observe = observeOption ? Number(observeOption.slice('--observe='.length)) : 650 + sweep * 1000;
// --aod folds from the always-on Lock Screen: before each fold the power
// button dims a lit screen, and the panel must stay on (panel-dark state 1).
const aod = options.includes('--aod');
const orientations = options.filter(x => !['--lock-rotation', '--match-panel-orientation', '--check-panel', '--guest-clock', '--aod', guestOption, settleOption, observeOption, appOption, pageOption, sweepOption].includes(x));
if (!socketArg || !outputArg || !/^[a-f0-9]{64}$/.test(expected ?? '') ||
    (guestOption && !['native', 'screenshot'].includes(guestCapture)) ||
    !Number.isInteger(settle) || settle < 0 ||
    !Number.isFinite(observe) || observe < 1 || observe > 12000 || (app && aod) ||
    (pageOption && (app !== 'com.apple.mobilesafari' || !/^http:\/\/192\.168\.\d{1,3}\.\d{1,3}:\d{1,5}\/[a-z0-9-]+$/.test(page))) ||
    !(sweep >= 0 && sweep <= 10) || (app !== undefined && !/^[A-Za-z0-9.-]+$/.test(app)) ||
    !orientations.length || orientations.some(x => !['portrait', 'landscape-left'].includes(x))) {
    throw Error('Usage: f5-clock.mjs <vphone.sock> <new output> <vphoned SHA-256> [--guest=native|screenshot] [--guest-clock] [--check-panel] [--lock-rotation] [--match-panel-orientation] [--settle=<ms>] [--observe=<ms>] [--app=<bundle id>] [--page=<local probe URL>] [--sweep=<s>] [--aod] <portrait|landscape-left> ...');
}
const socket = fs.realpathSync(socketArg);
const requestedOutput = path.resolve(outputArg);
const output = path.join(fs.realpathSync(path.dirname(requestedOutput)), path.basename(requestedOutput));
const build = path.join(root, '.build') + path.sep;
if (!socket.startsWith(build) || path.basename(socket) !== 'vphone.sock' || !fs.statSync(socket).isSocket() ||
    !output.startsWith(build)) throw Error('Expected a workspace test socket and output directory');
fs.mkdirSync(output);
process.chdir(path.dirname(socket));

const start = process.hrtime.bigint();
const now = () => Number(process.hrtime.bigint() - start) / 1e6;
// Wall clock at the monotonic origin, to match guest log lines (epoch seconds).
const epochAtStart = Date.now() - now();
function request(message) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        const client = net.createConnection('./vphone.sock', () => client.write(JSON.stringify(message) + '\n'));
        client.setTimeout(5000 + sweep * 1000, () => client.destroy(Error('host control timeout')));
        client.on('data', chunk => chunks.push(chunk));
        client.on('error', reject);
        client.on('end', () => {
            try { resolve(JSON.parse(Buffer.concat(chunks))); } catch (error) { reject(error); }
        });
    });
}
const rpc = (method, params = {}, options = {}) => request({ t: 'rpc', method, params, ...options });
const checked = async (method, params) => {
    const response = await rpc(method, params);
    if (!response.ok) throw Error(`${method}: ${response.error}`);
    return response.result;
};
const save = (name, value) => fs.writeFileSync(path.join(output, name), JSON.stringify(value, null, 2) + '\n');
const device = await checked('device.info');
save('device.json', { agent: device.agent, ios_version: device.ios_version });
save('clock.json', { epoch_ms_at_monotonic_zero: epochAtStart,
    host_uptime_ns_at_monotonic_zero: start.toString(),
    settle_ms: settle, observe_ms: observe, app, sweep_s: sweep, aod, guest_capture: guestCapture ?? null, guest_clock: guestClock });
if (device.agent?.binary_hash !== expected) throw Error('Guest daemon does not match the pinned build');
const geometry = await request({ t: 'display.geometry', screen: false });
if (geometry.result?.windowed !== true) throw Error('The VM must use windowed presentation capture');
await checked('screen.unlock', { timeout: 30 });
await checked('input.button', { name: 'home' });
let appPID;

async function calibrateGuestClock(file) {
    if (!guestClock) return;
    const samples = [];
    for (let i = 0; i < 5; i++) {
        const sent = now();
        const reply = await rpc('device.info', {}, { screen: false, delay: 0 });
        const received = now();
        if (!reply.ok || !Number.isFinite(reply.result?.uptime_seconds)) throw Error('Guest uptime unavailable');
        samples.push({ sent, received, guest_uptime_ms: reply.result.uptime_seconds * 1000,
            boot_session_uuid: reply.result.boot_session_uuid });
    }
    save(file, samples);
}

async function checkForeground(file) {
    const state = await checked('apps.foreground');
    save(file, state);
    if (state.verified !== true || state.bundle_id !== app || !(appPID > 0) || state.pid !== appPID) {
        throw Error(`Foreground application changed: ${JSON.stringify(state)}`);
    }
}

const aodNotifications = ['com.apple.springboard.hasBlankedScreen', 'com.vphone.folddisplay.panel-dark'];
const aodNotify = () => Promise.all(aodNotifications.map(name => checked('notify.state', { name })));

async function readAlwaysOn(file) {
    const sent = now();
    const [snapshot, [blanked, panel], presentation] = await Promise.all([
        checked('device.snapshot'), aodNotify(), rpc('display.orientation', {}, { screen: true, delay: 0 }),
    ]);
    if (presentation.image) fs.writeFileSync(path.join(output, file.replace(/\.json$/, '.jpg')), Buffer.from(presentation.image, 'base64'));
    const state = { sent, received: now(), lock: snapshot.lock, blanked, panel, orientation: presentation.result };
    save(file, state);
    return state;
}

const isAlwaysOn = ({ lock, blanked, panel }) => lock?.locked === true && lock.screen_off === true && blanked?.state === 1 && panel?.state === 1;
const aodFailures = [];

async function panelSnapshot(file) {
    const sent = now();
    const reply = await rpc('display.capture_active');
    const { base64, ...metadata } = reply.result ?? {};
    const { source, source_after: after } = metadata;
    const stable = reply.ok && metadata.available === true && metadata.format === 'png' && typeof base64 === 'string'
        && Number.isInteger(source?.display_id) && source.display_id === after?.display_id && source.name === after.name;
    const panel = stable ? (source.name === 'VPhone Duo Inner' ? 'inner display' : source.name === 'LCD' ? 'cover' : null) : null;
    save(file, { sent, received: now(), panel, metadata, error: reply.error });
}

async function sampleBlock(block, orientation) {
    if (lockRotation) await checked('display.rotation_lock', { locked: false });
    const poseOrientation = hinge => orientation === 'portrait'
        ? (hinge === 'open' ? 3 : 1) : (hinge === 'open' ? 1 : 4);
    const posture = hinge => ({ hinge, ...(holdInterface ? { orientation: poseOrientation(hinge) } : {}) });
    const fold = hinge => sweep
        ? { position: hinge === 'open' ? 'open' : 'closed', duration: sweep, profile: 'continuous',
            ...(holdInterface ? { orientation: poseOrientation(hinge) } : {}) }
        : posture(hinge);
    await checked('display.posture', posture('closed'));
    const rotation = await rpc('display.rotation', { orientation });
    await sleep(400);
    const initial = await checked('display.orientation');
    const degrees = orientation === 'portrait' ? 0 : 90;
    save(`block-${block}.json`, { orientation, rotation, initial });
    if (initial.degrees !== degrees || typeof initial.fold_angle !== 'number' ||
        initial.fold_angle > 5 || initial.screen_off !== false) {
        throw Error(`Could not establish ${orientation} on the lit cover`);
    }
    if (lockRotation) {
        const lock = await checked('display.rotation_lock', { locked: true });
        save(`block-${block}-lock.json`, lock);
        if (lock.locked !== true) throw Error('Rotation lock did not apply');
    }
    if (app) {
        const launched = await checked('apps.launch', { bundle_id: app });
        save(`block-${block}-app-launch.json`, launched);
        appPID = launched.pid;
        if (page) await checked('apps.open_url', { url: page });
        await sleep(3000);
        await checkForeground(`block-${block}-app-ready.json`);
    }
    for (let trial = 1; trial <= 3; trial++) {
        for (const hinge of ['open', 'closed']) {
            const name = `${block}-${trial}-${hinge}`;
            const folder = path.join(output, name);
            fs.mkdirSync(folder);
            if (aod) {
                const initial = await readAlwaysOn(`${name}/aod-initial.json`);
                if (!isAlwaysOn(initial) && !initial.lock?.screen_off) {
                    await checked('input.button', { name: 'power' });
                    await sleep(2500);
                }
                const before = await readAlwaysOn(`${name}/aod-before.json`);
                if (!isAlwaysOn(before)) throw Error(`Could not enter Always On before ${name}: ${JSON.stringify(before)}`);
                if (trial === 1 && hinge === 'open') {
                    await sleep(observe + settle);
                    const control = await readAlwaysOn(`${name}/aod-no-fold-control.json`);
                    if (!isAlwaysOn(control)) throw Error(`Always On state changed before the no-fold control finished: ${JSON.stringify(control)}`);
                }
            }
            if (app) await checkForeground(`${name}/app-before.json`);
            if (checkPanel) await panelSnapshot(`${name}/panel-before.json`);
            const before = await checked('display.orientation');
            await calibrateGuestClock(`${name}/clock-before.json`);
            const frames = [];
            const guestFrames = [];
            const notifySamples = [];
            let stop = false;
            const notifySampler = !aod ? null : (async () => {
                while (!stop) {
                    const sent = now();
                    try {
                        const [blanked, panel] = await aodNotify();
                        notifySamples.push({ sent, received: now(), blanked: blanked.state, panel: panel.state });
                    } catch (error) {
                        notifySamples.push({ sent, received: now(), error: String(error) });
                    }
                    await sleep(70);
                }
            })();
            const guestSampler = !guestCapture ? null : (async () => {
                const native = guestCapture === 'native';
                while (!stop) {
                    const sent = now();
                    let sample;
                    try {
                        const response = await rpc(native ? 'display.capture_active' : 'screen.screenshot');
                        const received = now();
                        const { base64, data, ...metadata } = response.result ?? {};
                        sample = { sent, received, metadata, error: response.error };
                        const encoded = native ? base64 : data;
                        if (response.ok && typeof encoded === 'string' &&
                            (native ? metadata.available === true && metadata.format === 'png' : metadata.mime_type === 'image/jpeg')) {
                            sample.file = `guest-${guestFrames.length}.${native ? 'png' : 'jpg'}`;
                            fs.writeFileSync(path.join(folder, sample.file), Buffer.from(encoded, 'base64'));
                        }
                    } catch (error) {
                        sample = { sent, received: now(), error: String(error) };
                    }
                    guestFrames.push(sample);
                    await sleep(15);
                }
            })();
            // The existing RPC returns both the guest orientation and a compact
            // screenshot from the same host presentation path as the recorder.
            const sampler = (async () => {
                while (!stop) {
                    const sent = now();
                    let sample;
                    try {
                        const response = await rpc('display.orientation', {}, { screen: true, delay: 0 });
                        sample = { sent, received: now(), state: response.result, error: response.error };
                        if (typeof response.image === 'string') {
                            sample.frame = frames.length;
                            fs.writeFileSync(path.join(folder, 'frames.mjpeg'), Buffer.from(response.image, 'base64'), { flag: 'a' });
                        }
                    } catch (error) {
                        sample = { sent, received: now(), error: String(error) };
                    }
                    frames.push(sample);
                    await sleep(15);
                }
            })();
            let action;
            try {
                await sleep(page ? 1200 : 140);
                const sent = now();
                const params = fold(hinge);
                const response = await rpc('display.posture', params);
                action = { sent, received: now(), params, response };
                await sleep(observe);
            } finally {
                stop = true;
                await Promise.all([sampler, guestSampler, notifySampler]);
                save(`${name}/samples.json`, frames);
                if (aod) save(`${name}/aod-notify.json`, notifySamples);
                if (guestCapture) save(`${name}/guest-samples.json`, guestFrames);
            }
            const after = await checked('display.orientation');
            await calibrateGuestClock(`${name}/clock-after.json`);
            save(`${name}/action.json`, { before, action, after, orientation, trial, hinge });
            if (!action.response.ok || typeof after.fold_angle !== 'number' ||
                (hinge === 'open' ? after.fold_angle < 175 : after.fold_angle > 5)) {
                throw Error(`Fold did not settle: ${name}`);
            }
            if (settle) await sleep(settle);
            if (checkPanel) await panelSnapshot(`${name}/panel-after.json`);
            if (app) await checkForeground(`${name}/app-after.json`);
            if (aod && !isAlwaysOn(await readAlwaysOn(`${name}/aod-after.json`))) aodFailures.push(name);
            console.log(name, `samples=${frames.filter(f => f.frame !== undefined).length}`,
                        `degrees=${before.degrees}->${after.degrees}`);
        }
    }
}

if (lockRotation && typeof device.rotation?.locked !== 'boolean') throw Error('Original rotation lock unavailable');
try {
    for (const [block, orientation] of orientations.entries()) await sampleBlock(block, orientation);
    if (aodFailures.length) throw Error(`Always On state changed after: ${aodFailures.join(', ')}`);
} finally {
    if (lockRotation) save('restored-lock.json', await checked('display.rotation_lock', { locked: device.rotation.locked }));
}
