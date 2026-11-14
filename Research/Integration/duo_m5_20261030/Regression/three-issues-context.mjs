// Compare application AX contexts and daemon-local display identity caches.
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
const device=await checked('device.info');
if(device.agent.binary_hash!=='446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b')throw Error('Unpinned daemon');
save('device.json',device);
async function processes(){
    const rows=[];
    for(const filter of ['SpringBoard','backboardd','vphoned'])rows.push({filter,...await checked('processes.list',{filter})});
    return rows;
}
async function display(label){
    const capture=await rpc('display.capture_active');
    const {base64,...metadata}=capture.result??{};
    const row={layout:await checked('display.layout'),capture:{ok:capture.ok,metadata,error:capture.error},processes:await processes()};
    save(label+'.json',row);
    if(base64)fs.writeFileSync(path.join(output,label+'.png'),Buffer.from(base64,'base64'));
    return row;
}
await checked('screen.unlock',{timeout:30});
await checked('display.posture',{hinge:'open-flat'});
await checked('display.rotation',{orientation:'portrait'});
await checked('input.button',{name:'home'});
await sleep(1800);
await display('cold-inner');
const contexts=[];
for(const app of ['com.apple.springboard','com.apple.Preferences','com.apple.springboard']){
    if(app==='com.apple.springboard')await checked('input.button',{name:'home'});
    else save('settings-launch.json',await rpc('apps.launch',{bundle_id:app}));
    await sleep(1500);
    const foreground=await checked('apps.foreground');
    if(foreground.bundle_id!==app||foreground.verified!==true)throw Error('Foreground precondition failed');
    const tree=await checked('ui.tree');
    const targets=tree.elements.filter(e=>e.x>10&&e.x<400&&e.y>70&&e.y<600).slice(0,3);
    const points=targets.length?targets.map(({x,y,label,identifier})=>({x,y,label,identifier})):[{x:200,y:300}];
    const hits=[];
    for(const point of points)hits.push({point,response:await rpc('ui.element_at',{x:point.x,y:point.y})});
    contexts.push({app,foreground,orientation:await checked('display.orientation'),tree,hierarchy:await rpc('ui.tree',{nested:true,max_depth:1,max_elements:64}),hits});
    save('ax-contexts.json',contexts);
}
save('respring.json',await checked('system.respring',{force:true}));
await sleep(4000);
await checked('screen.unlock',{timeout:30});
await checked('display.posture',{hinge:'open-flat'});
await sleep(1800);
await display('respring-inner');
const before=await checked('processes.list',{filter:'vphoned'});
save('daemon-before.json',before);
const kick=await rpc('services.kickstart',{label:'com.vphone.vphoned',kill:true,force:true}).catch(error=>({transport_error:String(error)}));
save('kickstart.json',kick);
let restarted=false;
for(let i=0;i<45;i++){
    await sleep(1000);
    const after=await rpc('processes.list',{filter:'vphoned'}).catch(error=>({transport_error:String(error)}));
    if(after.ok&&after.result.processes.some(p=>!before.processes.some(b=>b.pid===p.pid))){save('daemon-after.json',after.result);restarted=true;break;}
}
if(!restarted)throw Error('Daemon restart was not verified');
await sleep(2000);
await display('daemon-restarted-inner');
save('environment-after.json',await checked('environment.status'));
console.log(JSON.stringify(contexts.map(c=>({app:c.app,hits:c.hits.map(h=>({point:h.point,ok:h.response.ok,error:h.response.error}))})),null,2));
