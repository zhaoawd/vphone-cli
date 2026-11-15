// Replay recorded environment replies against an unchanged copy of the saved runtime script.
// The fake workspace and socket are private fixtures, never the real VM socket.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const regression = path.dirname(fileURLToPath(import.meta.url));
const [baselineFile, candidateFile, evidence] = process.argv.slice(2);
if (!evidence) throw Error('Usage: test-camera-runtime-guards.mjs <original-cache-state.json> <candidate environment.json> <new evidence directory>');
const original = JSON.parse(fs.readFileSync(baselineFile, 'utf8'));
const recorded = JSON.parse(fs.readFileSync(candidateFile, 'utf8'));
const candidate = recorded.result ?? recorded;
assert.equal(candidate.libraries.length, 21);
assert.equal(candidate.libraries.find(row => row.name === 'SystemHook-vphone.dylib').sha256,
    '6aa02df8eacfe8d94fd85ea6cf701e8d612f29b018c9407deb4d7bc0dde28217');
assert.equal(fs.existsSync(evidence), false);
fs.mkdirSync(evidence, {recursive: true});
const source = fs.readFileSync(path.join(regression, 'camera-web-runtime.mjs'));
const cwd = process.cwd(), results = [];
for (const name of ['candidate', 'original', 'writable', 'other-library', 'missing-library', 'wrong-daemon', 'session-escape']) {
    const root = path.resolve(evidence, name);
    const localRegression = path.join(root, 'Research/Integration/duo_m5_20261030/Regression');
    const task = path.join(root, '.build/host-webcam-distribution-20261115');
    const machine = path.join(root, '.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-20261115');
    const session = path.join(task, 'mixed-session.fixture');
    for (const dir of [localRegression, machine, session]) fs.mkdirSync(dir, {recursive: true});
    const script = path.join(localRegression, 'camera-web-runtime.mjs');
    fs.writeFileSync(script, source);
    assert.deepEqual(fs.readFileSync(script), source);
    fs.writeFileSync(path.join(task, 'original-cache-state.json'), JSON.stringify(original));
    fs.writeFileSync(path.join(task, 'active-mixed-session.txt'), name === 'session-escape' ? root : session);
    const environment = structuredClone(name === 'original' ? original.environment : candidate);
    if (name === 'writable') environment.root_read_only = false;
    if (name === 'other-library') environment.libraries.find(row => row.sha256 && row.name !== 'SystemHook-vphone.dylib').sha256 = '0'.repeat(64);
    if (name === 'missing-library') environment.libraries.pop();
    const methods = [];
    process.chdir(machine);
    const server = net.createServer(socket => {
        let request = '';
        socket.on('data', chunk => {
            request += chunk;
            if (!request.includes('\n')) return;
            const {method} = JSON.parse(request);
            methods.push(method);
            let reply;
            if (method === 'device.info') reply = {ok: true, result: {agent: {binary_hash: name === 'wrong-daemon' ? '0'.repeat(64) : '446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b'}}};
            else if (method === 'environment.status') reply = {ok: true, result: environment};
            else reply = {ok: false, error: 'fixture_stop_after_guards'};
            socket.end(JSON.stringify(reply));
        });
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen('vphone.sock', resolve); });
    let stderr = '';
    const child = spawn(process.execPath, [script, 'accept'], {stdio: ['ignore', 'ignore', 'pipe']});
    child.stderr.on('data', chunk => { stderr += chunk; });
    const status = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    await new Promise(resolve => server.close(resolve));
    process.chdir(cwd);
    fs.writeFileSync(path.join(root, 'stderr.log'), stderr);
    assert.equal(status, 1);
    if (name === 'candidate') {
        assert.deepEqual(methods, ['device.info', 'environment.status', 'environment.status', 'processes.list']);
        assert.match(stderr, /fixture_stop_after_guards/);
    } else {
        assert(!methods.includes('processes.list'), name + ' must stop before any camera action');
        assert.match(stderr, /AssertionError/);
    }
    results.push({name, passed: true, methods});
}
fs.writeFileSync(path.resolve(evidence, 'results.json'), JSON.stringify({scope: 'Recorded RPC guard replay, not a guest camera test', results}, null, 2) + '\n');
console.log('7 saved camera runtime guard cases passed; no real VM connection or camera action');
