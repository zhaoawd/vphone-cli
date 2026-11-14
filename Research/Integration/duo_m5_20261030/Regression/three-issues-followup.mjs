// Compare cold-start and respring display identity on the original library,
// then capture wake logs during isolated always-on fold requests.
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
const [socketArg, outputArg] = process.argv.slice(2);
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
save('environment-before.json',await checked('environment.status'));
async function display(label){
    await checked('screen.unlock',{timeout:30});
    await checked('display.posture',{hinge:'open-flat'});
    await checked('display.rotation',{orientation:'portrait'});
    await sleep(2000);
    const capture=await rpc('display.capture_active');
    const {base64,...metadata}=capture.result??{};
    const tree=await checked('ui.tree');
    const target=tree.elements.find(e=>e.identifier==='Settings');
    const hit=target?await rpc('ui.element_at',{x:target.x,y:target.y}):null;
    save(label+'.json',{layout:await checked('display.layout'),orientation:await checked('display.orientation'),capture:{ok:capture.ok,metadata,error:capture.error},
        hierarchy:await rpc('ui.tree',{nested:true,max_depth:1,max_elements:64}),hit});
    if(base64)fs.writeFileSync(path.join(output,label+'.png'),Buffer.from(base64,'base64'));
}
await display('cold-inner');
save('respring.json',await checked('system.respring',{force:true}));
await sleep(4000);
await display('respring-inner');
save('refresh-modes.json',await checked('display.modes'));
await display('refreshed-inner');
// Restore the cover and close before observing wakes, leaving the original
// library and root mount untouched throughout this run.
const aod=[];
const blanked=async()=>{
    const sent=now();
    const [snapshot,b,p]=await Promise.all([checked('device.snapshot'),checked('notify.state',{name:'com.apple.springboard.hasBlankedScreen'}),checked('notify.state',{name:'com.vphone.folddisplay.panel-dark'})]);
    return {sent,received:now(),lock:snapshot.lock,blanked:b.state,panel:p.state};
};
for(const target of ['control','closed','open']){
    await checked('screen.unlock',{timeout:30});
    await checked('display.posture',{hinge:target==='closed'?'open':'closed'});
    await sleep(2200);await checked('input.button',{name:'power'});await sleep(2200);
    const before=await blanked();
    if(!before.lock.locked||!before.lock.screen_off||before.blanked!==1||before.panel!==1)throw Error('Always-on precondition failed');
    const streams=['vphoned','SpringBoard'].map(async process=>({process,reply:await rpc('logs.syslog',{seconds:4,process,max_lines:1000,
        message_contains:process==='vphoned'?'tap to wake':'unlockUIFromSource'})}));
    await sleep(300);
    const sent=now();
    const response=target==='control'?null:await rpc('display.posture',{hinge:target});
    const received=now();
    await sleep(1200);
    const after=await blanked();
    const logs=await Promise.all(streams);
    const row={target,before,sent,received,response,after,logs};
    aod.push(row);save('wake-logs.json',aod);
}
save('environment-after.json',await checked('environment.status'));
console.log(JSON.stringify(aod.map(r=>({target:r.target,before:r.before.blanked,after:r.after.blanked,logs:r.logs.map(l=>({process:l.process,ok:l.reply.ok}))})),null,2));
