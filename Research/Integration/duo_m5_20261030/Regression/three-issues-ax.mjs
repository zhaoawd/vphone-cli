// Require display-scoped native hits for Home and Settings, including rotated apps.
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
if((await checked('device.info')).agent.binary_hash!==expectedAgent)throw Error('Unpinned daemon');
const rows=[];
for(const hinge of ['closed','open-flat']){
  await checked('screen.unlock',{timeout:30});await checked('display.posture',{hinge});
  for(const app of ['com.apple.springboard','com.apple.Preferences']){
    for(const orientation of app==='com.apple.springboard'||hinge==='closed'?['portrait']:['portrait','landscape-left']){
      if(app==='com.apple.springboard')await checked('input.button',{name:'home'});
      else await checked('apps.launch',{bundle_id:app});
      await checked('display.rotation',{orientation});
      await sleep(1500);
      const foreground=await checked('apps.foreground');
      if(foreground.bundle_id!==app||foreground.verified!==true)throw Error('Foreground precondition failed');
      const layout=await checked('display.layout'),tree=await checked('ui.tree');
      const points=tree.elements.filter(e=>e.identifier&&e.clickable&&e.x>10&&e.y>70).slice(0,3);
      if(points.length!==3)throw Error('Three visible AX targets required');
      const hits=[];
      for(const point of points){
        const reply=await rpc('ui.element_at',{x:point.x,y:point.y});
        hits.push({point,response:reply});
      }
      rows.push({hinge,app,orientation,foreground,layout,hits});save('hits.json',rows);
    }
  }
}
await checked('display.rotation',{orientation:'portrait'});await checked('input.button',{name:'home'});
await checked('input.button',{name:'power'});await sleep(1800);
const lock=await checked('device.snapshot');
if(lock.lock.locked!==true)throw Error('Lock precondition failed');
save('locked-hit.json',await rpc('ui.element_at',{x:200,y:300}));
await checked('screen.unlock',{timeout:30});
let failures=0;
for(const row of rows)for(const hit of row.hits)if(!hit.response.ok||hit.response.result.element?.identifier!==hit.point.identifier)failures++;
const locked=JSON.parse(fs.readFileSync(path.join(output,'locked-hit.json')));
if(locked.ok)failures++;
console.log(JSON.stringify({hits:rows.reduce((n,r)=>n+r.hits.length,0),failures,lockedRejected:!locked.ok}));
if(failures)throw Error('AX target identity regression failed');
