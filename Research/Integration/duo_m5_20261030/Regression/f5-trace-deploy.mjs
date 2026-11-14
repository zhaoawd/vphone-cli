// Narrow, reversible deployment for the named disposable VM only.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { validateTraceBaseline } from './f5-trace-state.mjs';

const [socketArg, outputArg, candidateArg, action] = process.argv.slice(2);
const root = fs.realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const socket = fs.realpathSync(socketArg ?? '.');
const output = fs.realpathSync(outputArg ?? '.');
const candidate = action === 'restore' ? path.resolve(candidateArg ?? '.') : fs.realpathSync(candidateArg ?? '.');
if (!['prepare', 'install', 'restore'].includes(action) ||
    socket !== path.join(root, '.build/duo-runtime-84e3ce54/machines/duo-rpc-accept-205443/vphone.sock') ||
    !output.startsWith(root + '/.build/') || !candidate.startsWith(root + '/.build/f5-hold-trace/')) {
    throw Error('Expected the pinned isolated VM, workspace evidence directory, and diagnostic candidate');
}
process.chdir(path.dirname(socket));
const library = 'libvphonefolddisplay.dylib';
const guestPath = '/usr/lib/' + library;
const marker = '/var/mobile/Library/Caches/vphone-folddisplay-trace.enabled';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const save = (name, value) => fs.writeFileSync(path.join(output, name), JSON.stringify(value, null, 2) + '\n');
const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    const chunks = [];
    const client = net.createConnection('./vphone.sock', () => client.write(JSON.stringify({ t: 'rpc', method, params, screen: false }) + '\n'));
    client.setTimeout(45000, () => client.destroy(Error('Guest request timed out')));
    client.on('data', chunk => chunks.push(chunk));
    client.on('error', reject);
    client.on('end', () => {
        try {
            const response = JSON.parse(Buffer.concat(chunks));
            if (!response.ok) throw Error(`${method}: ${response.error}`);
            resolve(response.result);
        } catch (error) { reject(error); }
    });
});
const readLibrary = async () => {
    const result = await rpc('files.read', { path: guestPath, binary: true, limit: 524288 });
    if (result.truncated || result.encoding !== 'base64') throw Error('Incomplete library backup');
    return Buffer.from(result.content, 'base64');
};
const device = await rpc('device.info');
if (device.agent?.binary_hash !== '446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b') throw Error('Guest daemon differs from the pinned build');
const environment = await rpc('environment.status');
const planPath = path.join(output, 'trace-deployment.json');
if (action === 'prepare') {
    if (fs.existsSync(planPath)) throw Error('A deployment plan already exists');
    const original = await readLibrary();
    validateTraceBaseline({ originalSHA256: hash(original), candidateSHA256: hash(fs.readFileSync(candidate)),
        rootReadOnly: environment.root_read_only });
    const entries = await rpc('files.list', { path: '/usr/lib' });
    const entry = entries.entries.find(row => row.name === library);
    if (!entry || entry.type !== 'file' || entry.perm !== '755') throw Error('Expected a regular 0755 FoldDisplay library');
    const cache = await rpc('files.list', { path: path.posix.dirname(marker) });
    const markerExists = cache.entries.some(row => row.path === marker);
    const originalMarker = markerExists ? await rpc('files.read', { path: marker, limit: 16 }) : null;
    if (originalMarker?.truncated) throw Error('Unexpected pre-existing diagnostic marker');
    fs.writeFileSync(path.join(output, 'original-folddisplay.dylib'), original, { flag: 'wx' });
    const plan = { guest: guestPath, patch: 'system-springboard-cfw-fold_display',
        originalSHA256: hash(original), candidateSHA256: hash(fs.readFileSync(candidate)), originalMarker,
        environment, steps: ['Upload only FoldDisplay via environment.install', 'Enable trace and respring',
            'Record six folds with guest uptime brackets', 'Restore original bytes and marker, respring, verify all library hashes and root mount mode'] };
    if (environment.libraries.find(row => row.name === library)?.sha256 !== plan.originalSHA256) throw Error('Library changed during preparation');
    save('trace-deployment.json', plan);
    console.log(JSON.stringify({ action, originalSHA256: plan.originalSHA256, candidateSHA256: plan.candidateSHA256,
        rootReadOnly: environment.root_read_only }, null, 2));
} else {
    const plan = JSON.parse(fs.readFileSync(planPath));
    validateTraceBaseline({ originalSHA256: plan.originalSHA256, candidateSHA256: plan.candidateSHA256,
        rootReadOnly: plan.environment.root_read_only });
    const original = fs.readFileSync(path.join(output, 'original-folddisplay.dylib'));
    const diagnostic = action === 'install' ? fs.readFileSync(candidate) : null;
    if (hash(original) !== plan.originalSHA256 || (diagnostic && hash(diagnostic) !== plan.candidateSHA256)) throw Error('Deployment files changed after preparation');
    const current = hash(await readLibrary());
    if (![plan.originalSHA256, plan.candidateSHA256].includes(current)) throw Error('Guest library changed outside this experiment');
    if (action === 'install' && current !== plan.originalSHA256) throw Error('Candidate is already installed');
    const bytes = action === 'install' ? diagnostic : original;
    if (hash(bytes) !== current) {
        const staging = environment.staging + '/' + library;
        save(action + '-upload.json', await rpc('files.write', { path: staging, content: bytes.toString('base64'), encoding: 'base64' }));
        save(action + '-environment.json', await rpc('environment.install', { libraries: [{ name: library, sha256: hash(bytes) }] }));
    }
    const markerContent = action === 'install' ? '1' : (plan.originalMarker?.content ?? '0');
    await rpc('files.write', { path: marker, content: markerContent,
        encoding: action === 'install' ? 'utf8' : (plan.originalMarker?.encoding ?? 'utf8') });
    save(action + '-respring.json', await rpc('system.respring', { force: true }));
    const after = await rpc('environment.status');
    if (hash(await readLibrary()) !== hash(bytes)) throw Error('Installed bytes do not match');
    for (const row of plan.environment.libraries.filter(row => row.name !== library)) {
        if (after.libraries.find(other => other.name === row.name)?.sha256 !== row.sha256) throw Error('An unrelated library changed');
    }
    const rootModeRestored = after.root_read_only === plan.environment.root_read_only;
    save(action + '-verified.json', { sha256: hash(bytes), root_read_only: after.root_read_only,
        unrelatedLibrariesUnchanged: true, rootModeRestored, rebootRequired: !rootModeRestored });
    console.log(JSON.stringify({ action, sha256: hash(bytes), bytesVerified: true, rootModeRestored, rebootRequired: !rootModeRestored }));
}
