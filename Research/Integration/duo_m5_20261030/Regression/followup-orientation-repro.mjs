// Reproduce a portrait request after Safari resumes a landscape scene.
// Keep failures as evidence; a passing Home restoration does not pass Safari.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const [socket, output, overallDaemon] = process.argv.slice(2);
const machine=path.basename(path.dirname(socket ?? ''));
assert(['duo-cfw-followup-20261115','duo-overall-20261116'].includes(machine));
if(machine==='duo-overall-20261116')assert(/^[a-f0-9]{64}$/.test(overallDaemon??''));
assert(output && !fs.existsSync(output));
fs.mkdirSync(output, {recursive: true});
process.chdir(path.dirname(socket));
const raw = (method, params = {}) => new Promise((resolve, reject) => {
    const chunks = [], c = net.createConnection('./vphone.sock', () => c.write(JSON.stringify({t: 'rpc', method, params, screen: false}) + '\n'));
    c.setTimeout(30000, () => c.destroy(Error('RPC timeout')));
    c.on('data', b => chunks.push(b)); c.on('error', reject);
    c.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks))); } catch (e) { reject(e); } });
});
const rpc = async (m, p) => { const r = await raw(m, p); assert.equal(r.ok, true, m + ': ' + JSON.stringify(r.error)); return r.result; };
const save = (name, value) => fs.writeFileSync(path.join(output, name + '.json'), JSON.stringify(value, null, 2) + '\n');
const device = await rpc('device.info');
assert.equal(device.agent.binary_hash,machine==='duo-overall-20261116'?overallDaemon:'c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593');
const original = {device, orientation: await rpc('display.orientation'), autoLock: await rpc('display.auto_lock')};
save('before', original);
assert.equal(original.orientation.fold_angle, 0); assert.equal(original.orientation.degrees, 0);
assert.equal(device.rotation.locked, false);
async function state() {
    const plist = await rpc('files.plist', {path: '/var/mobile/Library/Preferences/com.apple.backboardd.plist'});
    return {orientation: await rpc('display.orientation'), foreground: await rpc('apps.foreground'),
        configuration: plist.plist.VPhoneHingeAngle, status: plist.plist.VPhoneHingeStatus};
}
async function foreground(bundleID) {
    let stable = 0;
    for (let attempt = 0; attempt < 40; attempt++) {
        const value = await rpc('apps.foreground');
        stable = value.verified === true && value.bundle_id === bundleID ? stable + 1 : 0;
        if (stable >= 2) return;
        await sleep(250);
    }
    throw Error('Foreground precondition did not settle: ' + bundleID);
}
const results = [];
let primaryError;
try {
    await rpc('screen.unlock', {timeout: 30});
    for (let trial = 0; trial < 3; trial++) {
        await rpc('input.button', {name: 'home'});
        await foreground('com.apple.springboard');
        await rpc('display.posture', {hinge: 'closed', orientation: 'portrait'});
        await rpc('apps.launch', {bundle_id: 'com.apple.mobilesafari'});
        await foreground('com.apple.mobilesafari');
        const landscapeRequest = await raw('display.rotation', {orientation: '270'});
        const landscape = await state();
        save('landscape-' + trial, {request: landscapeRequest, state: landscape});
        assert.equal(landscapeRequest.ok, true);
        assert.equal(landscape.orientation.degrees, 270, 'The landscape precondition did not apply');
        await rpc('input.button', {name: 'home'});
        await foreground('com.apple.springboard');
        await rpc('display.rotation', {orientation: '0'});
        await rpc('apps.launch', {bundle_id: 'com.apple.mobilesafari'});
        await foreground('com.apple.mobilesafari');
        await sleep(1000);
        const before = await state();
        const request = await raw('display.rotation', {orientation: '0'});
        const after = await state();
        const edge90 = await raw('display.rotation', {orientation: '90'});
        const after90 = await state();
        const edge0 = await raw('display.rotation', {orientation: '0'});
        const afterEdge = await state();
        const result = {trial, before, request, after, edge90, after90, edge0, afterEdge,
            passed: request.ok === true && after.orientation.degrees === 0};
        results.push(result); save('trial-' + trial, result);
    }
} catch (e) { primaryError = e; save('failure', {message: e.message, stack: e.stack}); }
finally {
    save('results', results);
    try {
        await rpc('screen.unlock', {timeout: 30}); await rpc('input.button', {name: 'home'});
        await rpc('display.posture', {hinge: 'closed', orientation: 'portrait'}); await sleep(1000);
        await rpc('display.rotation', {orientation: '0'});
        if (device.lock.locked && !(await rpc('device.info')).lock.locked) await rpc('input.button', {name: 'power'});
        let restoredDevice;
        for (let attempt = 0; attempt < 20; attempt++) {
            restoredDevice = await rpc('device.info');
            if (restoredDevice.lock.locked === device.lock.locked) break;
            await sleep(250);
        }
        const restored = {device: restoredDevice, orientation: await rpc('display.orientation'), autoLock: await rpc('display.auto_lock')};
        save('restored', restored);
        assert.deepEqual(restored.autoLock, original.autoLock);
        assert.equal(restored.orientation.degrees, 0); assert.equal(restored.orientation.fold_angle, 0);
        assert.equal(restored.device.lock.locked, device.lock.locked);
        assert.equal(restored.device.rotation.locked, device.rotation.locked);
    } catch (e) { save('restoration-failure', {message: e.message}); primaryError ??= e; }
}
if (primaryError) throw primaryError;
console.log(JSON.stringify(results.map(r => ({trial: r.trial, before: r.before.orientation.degrees,
    after: r.after.orientation.degrees, passed: r.passed, afterEdge: r.afterEdge.orientation.degrees}))));
assert.equal(results.length, 3);
assert(results.every(r => r.passed), 'Safari did not apply every portrait request after scene resumption');
