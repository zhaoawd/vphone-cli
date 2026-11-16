import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,baselineArg,outArg]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),baseline=fs.realpathSync(baselineArg),out=path.resolve(outArg);
assert(['duo-patches-20261116','duo-txm-remap-20261116'].includes(path.basename(path.dirname(socket))));
for(const p of [socket,baseline,out])assert(p.startsWith(root+'/.build/'));
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const load=name=>JSON.parse(fs.readFileSync(baseline+'/'+name+'.json'));
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
const pose=load('pose'),lock=load('auto-lock'),device=load('device');
const current=await rpc('device.info');assert.equal(current.agent.binary_hash,device.agent.binary_hash);
await rpc('screen.unlock',{timeout:30});
save('pose-set',await rpc('display.posture',{hinge:pose.hinge,orientation:pose.orientation,tabletop:pose.tabletop}));
save('auto-lock-set',await rpc('display.auto_lock.set',lock.never?{never:true}:{seconds:lock.auto_lock_seconds}));
await rpc('input.button',{name:'home'});
if(device.lock.locked)await rpc('input.button',{name:'power'});
let restored;
for(let attempt=0;attempt<20;attempt++){
    await sleep(500);restored=await rpc('device.info');save('device-restored',restored);
    if(restored.lock.locked===device.lock.locked&&restored.lock.screen_off===device.lock.screen_off)break;
}
const actualPose=await rpc('display.pose'),actualLock=await rpc('display.auto_lock');
save('pose-restored',actualPose);save('auto-lock-restored',actualLock);
for(const key of ['hinge','orientation','tabletop'])assert.equal(actualPose[key],pose[key],key);
assert.equal(actualLock.never,lock.never);assert.equal(actualLock.auto_lock_seconds,lock.auto_lock_seconds);
assert.equal(restored.lock.locked,device.lock.locked);assert.equal(restored.lock.screen_off,device.lock.screen_off);
assert.equal(restored.low_power_mode.enabled,device.low_power_mode.enabled);
console.log(JSON.stringify({poseRestored:true,autoLockSeconds:actualLock.auto_lock_seconds,locked:restored.lock.locked,screenOff:restored.lock.screen_off,lowPowerUnchanged:true}));
