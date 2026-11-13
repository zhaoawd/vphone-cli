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
// --settle=<ms> waits after each fold, so SpringBoard does not merge folds
// made faster than its content mode transitions finish.
const settleOption = options.find(x => x.startsWith('--settle='));
const settle = settleOption ? Number(settleOption.slice('--settle='.length)) : 0;
const orientations = options.filter(x => !['--lock-rotation', '--match-panel-orientation', guestOption, settleOption].includes(x));
if (!socketArg || !outputArg || !/^[a-f0-9]{64}$/.test(expected ?? '') ||
    (guestOption && !['native', 'screenshot'].includes(guestCapture)) ||
    !Number.isInteger(settle) || settle < 0 ||
    !orientations.length || orientations.some(x => !['portrait', 'landscape-left'].includes(x))) {
    throw Error('Usage: f5-clock.mjs <vphone.sock> <new output> <vphoned SHA-256> [--guest=native|screenshot] [--lock-rotation] [--match-panel-orientation] [--settle=<ms>] <portrait|landscape-left> ...');
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
        client.setTimeout(5000, () => client.destroy(Error('host control timeout')));
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
save('clock.json', { epoch_ms_at_monotonic_zero: epochAtStart, settle_ms: settle });
if (device.agent?.binary_hash !== expected) throw Error('Guest daemon does not match the pinned build');
const geometry = await request({ t: 'display.geometry', screen: false });
if (geometry.result?.windowed !== true) throw Error('The VM must use windowed presentation capture');
await checked('screen.unlock', { timeout: 30 });
await checked('input.button', { name: 'home' });

async function sampleBlock(block, orientation) {
    if (lockRotation) await checked('display.rotation_lock', { locked: false });
    const poseOrientation = hinge => orientation === 'portrait'
        ? (hinge === 'open' ? 3 : 1) : (hinge === 'open' ? 1 : 4);
    const posture = hinge => ({ hinge, ...(holdInterface ? { orientation: poseOrientation(hinge) } : {}) });
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
    for (let trial = 1; trial <= 3; trial++) {
        for (const hinge of ['open', 'closed']) {
            const name = `${block}-${trial}-${hinge}`;
            const folder = path.join(output, name);
            fs.mkdirSync(folder);
            const before = await checked('display.orientation');
            const frames = [];
            const guestFrames = [];
            let stop = false;
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
                await sleep(140);
                const sent = now();
                const params = posture(hinge);
                const response = await rpc('display.posture', params);
                action = { sent, received: now(), params, response };
                await sleep(650);
            } finally {
                stop = true;
                await Promise.all([sampler, guestSampler]);
                save(`${name}/samples.json`, frames);
                if (guestCapture) save(`${name}/guest-samples.json`, guestFrames);
            }
            const after = await checked('display.orientation');
            save(`${name}/action.json`, { before, action, after, orientation, trial, hinge });
            if (!action.response.ok || typeof after.fold_angle !== 'number' ||
                (hinge === 'open' ? after.fold_angle < 175 : after.fold_angle > 5)) {
                throw Error(`Fold did not settle: ${name}`);
            }
            if (settle) await sleep(settle);
            console.log(name, `samples=${frames.filter(f => f.frame !== undefined).length}`,
                        `degrees=${before.degrees}->${after.degrees}`);
        }
    }
}

if (lockRotation && typeof device.rotation?.locked !== 'boolean') throw Error('Original rotation lock unavailable');
try {
    for (const [block, orientation] of orientations.entries()) await sampleBlock(block, orientation);
} finally {
    if (lockRotation) save('restored-lock.json', await checked('display.rotation_lock', { locked: device.rotation.locked }));
}
