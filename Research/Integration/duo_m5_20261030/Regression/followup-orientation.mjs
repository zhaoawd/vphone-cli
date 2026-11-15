import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';

const [socket, output, testApp = 'com.apple.mobilesafari'] = process.argv.slice(2);
const expectedDaemons = {
    'duo-rpc-foundation-20261115': '446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b',
    'duo-cfw-followup-20261115': 'c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593',
};
const expectedDaemon = expectedDaemons[path.basename(path.dirname(socket ?? ''))];
if (!output || !expectedDaemon) throw Error('Use an authorised foundation or CFW followup socket and a new evidence directory');
assert.equal(fs.existsSync(output), false);
fs.mkdirSync(output, {recursive: true});
process.chdir(path.dirname(socket));
const request = payload => new Promise((resolve, reject) => {
    const chunks = [], connection = net.createConnection('./' + path.basename(socket), () => connection.write(JSON.stringify({...payload, screen: false}) + '\n'));
    connection.setTimeout(30000, () => connection.destroy(Error('RPC timeout')));
    connection.on('data', chunk => chunks.push(chunk)); connection.on('error', reject);
    connection.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks))); } catch (error) { reject(error); } });
});
const raw = (method, params = {}) => request({t: 'rpc', method, params});
const rpc = async (method, params) => { const reply = await raw(method, params); assert.equal(reply.ok, true, method + ': ' + JSON.stringify(reply.error)); return reply.result; };
const save = (name, value) => fs.writeFileSync(path.join(output, name + '.json'), JSON.stringify(value, null, 2) + '\n');
async function waitForeground(bundleID) {
    let stable = 0;
    for (let attempt = 0; attempt < 40; attempt++) {
        const value = await rpc('apps.foreground');
        stable = value.verified === true && value.bundle_id === bundleID ? stable + 1 : 0;
        if (stable >= 2) return;
        await sleep(250);
    }
    throw Error('Foreground precondition did not settle: ' + bundleID);
}
const device = await rpc('device.info');
assert.equal(device.agent.binary_hash, expectedDaemon);
const app = await rpc('apps.info', {bundle_id: testApp});
const appPlist = await rpc('files.plist', {path: app.bundle_path + '/Info.plist'});
save('app-contract', {bundleID: testApp, info: app, plist: appPlist});
for (const orientation of ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']) {
    assert(appPlist.plist.UISupportedInterfaceOrientations?.includes(orientation), 'The outer-panel fixture must declare ' + orientation);
}
const before = await rpc('display.orientation'), autoLock = await rpc('display.auto_lock');
save('before', {device, orientation: before, autoLock});
const results = [];
let primaryError;
try {
    await rpc('screen.unlock', {timeout: 30});
    for (const [panel, hinge, expectedID] of [['outer', 'closed', 1], ['inner', 'open-flat', 7]]) {
        await rpc('display.posture', {hinge, orientation: 'portrait'}); await sleep(1500);
        await rpc('apps.launch', {bundle_id: testApp});
        await waitForeground(testApp);
        for (const degrees of [0, 90, 180, 270]) {
            const unsupported = panel === 'outer' ? degrees === 180 : degrees === 270;
            const reply = await raw('display.rotation', {orientation: String(degrees)});
            const after = await rpc('display.orientation');
            const foreground = await rpc('apps.foreground');
            assert(foreground.verified === true && foreground.bundle_id === testApp, 'Test app left the foreground');
            save(panel + '-' + degrees, {reply, after, foreground});
            if (unsupported) {
                const error = typeof reply.error === 'string' ? reply.error : JSON.stringify(reply.error);
                const passed = reply.ok === false && /no upside-down orientation/.test(error);
                results.push({panel, degrees, expected: 'relay refusal', passed, actual: reply});
                continue;
            }
            let capture = null;
            if (reply.ok === true && after.degrees === degrees) {
                const response = await raw('display.capture_active');
                if (response.ok && response.result?.available === true && typeof response.result.base64 === 'string') {
                    capture = response.result;
                    fs.writeFileSync(path.join(output, panel + '-' + degrees + '.png'), Buffer.from(capture.base64, 'base64'));
                    capture = {...capture, base64: undefined};
                } else capture = {...response.result, base64: undefined, error: response.error};
            }
            save(panel + '-' + degrees + '-capture', capture);
            results.push({panel, degrees, expected: 'applied interface orientation', passed: reply.ok === true && after.degrees === degrees,
                observedDegrees: after.degrees, nativeSourceConfirmed: capture?.available === true &&
                    capture.source?.display_id === expectedID && capture.source_after?.display_id === expectedID, capture});
        }
    }
} catch (error) {
    save('failure', {message: error.message, stack: error.stack});
    primaryError = error;
} finally {
    save('results', results);
    try {
        const angle = Number(before.fold_angle);
        assert(Number.isFinite(angle), 'Original fold angle required for restoration');
        const hinge = angle === 0 ? 'closed' : angle >= 175 ? 'open-flat' : 'partially-open';
        // Home provides a stable scene for restoring the original panel orientation.
        await rpc('screen.unlock', {timeout: 30});
        await rpc('input.button', {name: 'home'});
        await waitForeground('com.apple.springboard');
        await rpc('display.posture', {hinge, angle, orientation: 'portrait'}); await sleep(1000);
        await rpc('display.rotation', {orientation: String(before.degrees)});
        const current = await rpc('device.info');
        if ((device.lock?.locked || device.screen?.locked) && !(current.lock?.locked || current.screen?.locked)) {
            await rpc('input.button', {name: 'power'});
        }
        let restoredDevice;
        for (let attempt = 0; attempt < 20; attempt++) {
            restoredDevice = await rpc('device.info');
            if (restoredDevice.lock.locked === device.lock.locked) break;
            await sleep(250);
        }
        const restored = {orientation: await rpc('display.orientation'), autoLock: await rpc('display.auto_lock'), device: restoredDevice};
        save('restored', restored);
        assert.deepEqual(restored.autoLock, autoLock);
        assert.equal(restored.device.rotation.locked, device.rotation.locked);
        assert.equal(restored.orientation.degrees, before.degrees);
        assert.equal(restored.orientation.fold_angle, before.fold_angle);
        assert.equal(restored.device.lock.locked, device.lock.locked);
    } catch (error) {
        save('restoration-failure', {message: error.message, stack: error.stack});
        primaryError ??= error;
    }
}
if (primaryError) throw primaryError;
save('results', results);
console.log(JSON.stringify(results.map(({panel, degrees, expected, passed, observedDegrees, nativeSourceConfirmed}) =>
    ({panel, degrees, expected, passed, observedDegrees, nativeSourceConfirmed}))));
assert(results.every(row => row.passed && (row.expected === 'relay refusal' || row.nativeSourceConfirmed)),
    'Some requested orientation cases or native source identities did not meet their explicit expectations');
