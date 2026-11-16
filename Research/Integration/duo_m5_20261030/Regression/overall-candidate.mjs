// Verify the approved bundle independently of VM state changed by acceptance.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync,spawnSync} from 'node:child_process';
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const reviewed=root+'/.build/overall-port-20261116/REVIEWED';
const manifest=JSON.parse(fs.readFileSync(reviewed+'/manifest.json'));
assert.equal(manifest.sourceCommit,'7e18551b82b64d1acd06ba7af921f68b68ff2ad4');
assert.equal(manifest.version,'2.18.0');
assert.equal(manifest.vmCDHash,'5f3f79e7c4eaf331b1f0a438fcddf9042835ce19');
assert.equal(fs.realpathSync(manifest.bundle),reviewed+'/VPhone.bundle');
assert.equal(manifest.target,root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert.equal(Object.keys(manifest.files).length,197);
for(const [relative,expected] of Object.entries(manifest.files)){
    const file=path.join(manifest.bundle,relative);
    if(expected.symlink!==undefined)assert.equal(fs.readlinkSync(file),expected.symlink,relative);
    else assert.equal(createHash('sha256').update(fs.readFileSync(file)).digest('hex'),expected.sha256,relative);
}
execFileSync('/usr/bin/codesign',['--verify','--deep','--strict',manifest.bundle],{stdio:'pipe'});
const signature=spawnSync('/usr/bin/codesign',['-d','--verbose=4',manifest.bundle+'/Contents/MacOS/vphone-vm'],{encoding:'utf8'});
assert.equal(signature.status,0);assert(signature.stderr.includes('CDHash='+manifest.vmCDHash));
console.log(JSON.stringify({sourceCommit:manifest.sourceCommit,bundle:manifest.bundle,files:Object.keys(manifest.files).length,vmCDHash:manifest.vmCDHash,strictSignature:true}));
