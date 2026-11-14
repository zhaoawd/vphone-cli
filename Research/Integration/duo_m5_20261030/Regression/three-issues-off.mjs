// Preserve real-off opening wake while testing the always-on policy.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
const [socketArg, outputArg, expectedAgent] = process.argv.slice(2);
if(!/^[a-f0-9]{64}$/.test(expectedAgent??''))throw Error('Expected daemon SHA-256 required');
const root = fs.realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
const socket = fs.realpathSync(socketArg), output = path.resolve(outputArg);
if (!socket.startsWith(root+'/.build/') || !output.startsWith(root+'/.build/')) throw Error('Workspace VM required');
fs.mkdirSync(output);
process.chdir(path.dirname(socket));
const start=process.hrtime.bigint(), now=()=>Number(process.hrtime.bigint()-start)/1e6;
const save=(file,value)=>fs.writeFileSync(path.join(output,file),JSON.stringify(value,null,2)+'\n');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[];
    const client=net.createConnection('./vphone.sock',()=>client.write(JSON.stringify({t:'rpc',method,params,screen:false,delay:0})+'\n'));
    client.setTimeout(30000,()=>client.destroy(Error('RPC timeout')));
    client.on('data',b=>chunks.push(b));client.on('error',reject);
    client.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)));}catch(e){reject(e);}});
});
const checked=async(method,params)=>{const r=await rpc(method,params);if(!r.ok)throw Error(`${method}: ${r.error}`);return r.result;};
const device=await checked('device.info');
if(device.agent.binary_hash!==expectedAgent)throw Error('Unpinned daemon');
save('environment-before.json',await checked('environment.status'));
const original=await checked('power.low_power_mode');
if(typeof original.enabled!=='boolean')throw Error('Low power restoration value unavailable');
save('low-power-before.json',original);
async function state(){
  const [snapshot,blanked,panel]=await Promise.all([checked('device.snapshot'),checked('notify.state',{name:'com.apple.springboard.hasBlankedScreen'}),checked('notify.state',{name:'com.vphone.folddisplay.panel-dark'})]);
  return {lock:snapshot.lock,blanked:blanked.state,panel:panel.state};
}
const rows=[];
try{
  save('low-power-on.json',await checked('power.low_power_mode',{enabled:true}));
  for(const hinge of ['open','closed']){
    await checked('screen.unlock',{timeout:30});
    await checked('display.posture',{hinge:hinge==='open'?'closed':'open'});
    await sleep(4500);
    save(`low-power-${hinge}.json`,await checked('power.low_power_mode',{enabled:true}));
    await checked('screen.unlock',{timeout:30});
    await sleep(700);
    await checked('input.button',{name:'power'});await sleep(2200);
    let before=await state();
    const setup=[before];
    const isOff=s=>s.lock?.locked&&s.lock.screen_off&&s.blanked===1&&s.panel===2;
    for(let poll=0;!isOff(before)&&poll<30;poll++){
      await sleep(100);before=await state();setup.push(before);
    }
    if(!isOff(before)&&before.blanked===0){
      await checked('input.button',{name:'power'});await sleep(2200);
      before=await state();setup.push(before);
    }
    save(`off-setup-${hinge}.json`,{samples:setup,lowPower:await checked('power.low_power_mode')});
    if(!before.lock.locked||!before.lock.screen_off||before.blanked!==1||before.panel!==2)throw Error('Actual-off precondition failed');
    const response=await checked('display.posture',{hinge});await sleep(1800);
    const after=await state();rows.push({hinge,before,response,after});save('off-controls.json',rows);
    if(!after.lock.locked||after.lock.screen_off||after.blanked!==0||after.panel!==1)throw Error(`True-off ${hinge} no longer wakes the Lock Screen`);
  }
}finally{
  save('low-power-restored.json',await checked('power.low_power_mode',{enabled:original.enabled}));
}
save('environment-after.json',await checked('environment.status'));
console.log(JSON.stringify(rows.map(r=>({hinge:r.hinge,before:r.before,after:r.after}))));
