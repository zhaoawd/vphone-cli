// Read-only review of the fixed Duo restore candidate, before any restore.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const [source,candidate,out]=process.argv.slice(2).map(p=>path.resolve(p));
for(const p of [source,candidate,out])assert(p.startsWith(root+'/.build/'));
assert.equal(path.basename(source),'duo-patches-20261116');
assert.equal(path.basename(candidate),'duo-txm-remap-20261116');
fs.mkdirSync(out);
const folder='iPhone19,4_27.1_24A94425_Restore';
const txm=folder+'/Firmware/txm.iphoneos.research.im4p';
const files=execFileSync('rg',['--files',source+'/'+folder,'-g','*.im4p','-g','kernelcache*','-g','*.trustcache'],{encoding:'utf8'}).trim().split('\n').map(p=>p.slice(source.length+1));
// The only DMG modified by this fixed firmware pipeline is RestoreRamDisk.
files.push(folder+'/094-39914-031.dmg');
const hash=async file=>{const h=createHash('sha256');for await(const chunk of fs.createReadStream(file))h.update(chunk);return h.digest('hex')};
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const rows=[];
for(const file of files){const a=await hash(source+'/'+file),b=await hash(candidate+'/'+file);rows.push({path:file,source:a,candidate:b,equal:a===b});}
save('artifacts',rows);
assert.deepEqual(rows.filter(x=>!x.equal).map(x=>x.path),[txm]);
const load=directory=>JSON.parse(execFileSync('/usr/bin/plutil',['-convert','json','-o','-',directory+'/PatchPlan.plist'],{encoding:'utf8'}));
const a=load(source),b=load(candidate),boot=id=>/^(kernel|devicetree|txm|ibss|ibec|llb|avpbooter)-/.test(id);
const diff={added:b.EnabledPatches.filter(x=>!a.EnabledPatches.includes(x)&&boot(x)),removed:a.EnabledPatches.filter(x=>!b.EnabledPatches.includes(x)&&boot(x))};
save('plan',diff);assert.deepEqual(diff,{added:['txm-cfw-executable_remap'],removed:['txm-boot-precheck_admission']});
save('summary',{comparedFiles:rows.length,changedFiles:1,txmSHA256:rows.find(x=>x.path===txm).candidate,restorePerformed:false});
console.log(JSON.stringify({comparedFiles:rows.length,changedFiles:1,restorePerformed:false}));
