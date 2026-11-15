import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const output = path.resolve(process.argv[2]);
if (!output.startsWith(root + '/.build/')) throw Error('Evidence must remain under this repository .build');
fs.mkdirSync(output, {recursive: true});
const revision = '1316940501398ea279f960ee7d838f93885730d4';
const git = args => execFileSync('git', args, {cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
const groups = [
    {number: 867, merge: 'edaa02f0', component: 'DriverKit virtual USB'},
    {number: 877, merge: 'c7d096d9', component: 'DriverKit preset exclusions'},
    {number: 900, merge: '6f57024a', component: 'Trusted darwinOS and persistent Cryptex'},
    {number: 909, merge: 'b41ad87c', component: 'iPhone SE 3 iOS 18 and PCC GPU extraction'},
    {number: 910, merge: '0fadfde4', component: 'Local pairing'},
    {number: 911, merge: '12378954', component: 'PCC recovery vCPU count'},
    {number: 920, merge: '1518293c', component: 'Mouse input mode'},
    {number: 921, merge: 'bb82a72a', component: 'cloudOS 18 SPTM secondary CPU'},
    {number: 926, merge: '69d45fb7', component: 'iPad framebuffer orientation'},
];
for (const group of groups) {
    group.merge = git(['rev-parse', group.merge]).trim();
    const files = git(['diff', '--name-only', group.merge + '^1', group.merge]).trim().split('\n');
    group.files = files.map(file => {
        let local;
        try { local = git(['rev-parse', 'HEAD:' + file]).trim(); } catch { local = null; }
        const upstream = git(['rev-parse', revision + ':' + file]).trim();
        return {file, localBlob: local, upstreamBlob: upstream,
            state: local === null ? 'absent' : local === upstream ? 'identical' : 'different'};
    });
    fs.writeFileSync(path.join(output, group.number + '-merge.diff'), git(['diff', group.merge + '^1', group.merge]));
    // Final-state comparison includes subsequent fixes at the pinned revision.
    fs.writeFileSync(path.join(output, group.number + '-final.diff'), git(['diff', 'HEAD', revision, '--', ...files]));
}
const report = {head: git(['rev-parse', 'HEAD']).trim(), upstream: revision, groups,
    scope: 'Blob comparison and final upstream diffs; different includes local adaptations and is not proof that every hunk is missing.'};
fs.writeFileSync(path.join(output, 'upstream-inventory.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(groups.map(g => ({number: g.number, files: g.files.length,
    identical: g.files.filter(f => f.state === 'identical').length,
    absent: g.files.filter(f => f.state === 'absent').length,
    different: g.files.filter(f => f.state === 'different').length})), null, 2));
