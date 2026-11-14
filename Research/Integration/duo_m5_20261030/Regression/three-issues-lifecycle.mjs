// Require automatic renderer-client recovery after a real SpringBoard restart.
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
save('environment-before.json',await checked('environment.status'));
async function processes(){
  return Promise.all(['vphoned','SpringBoard','backboardd'].map(async filter=>({filter,...await checked('processes.list',{filter})})));
}
async function capture(label){
  await checked('screen.unlock',{timeout:30});
  await checked('display.posture',{hinge:'open-flat'});
  await sleep(1800);
  const layout=await checked('display.layout'),reply=await checked('display.capture_active');
  const {base64,...metadata}=reply;
  save(label+'.json',{layout,capture:metadata,processes:await processes()});
  if(base64)fs.writeFileSync(path.join(output,label+'.png'),Buffer.from(base64,'base64'));
  if(metadata.available!==true)throw Error('Native source did not recover after renderer restart');
}
await capture('before');
const before=await checked('device.info');
if(before.agent.binary_hash!==expectedAgent)throw Error('Unpinned daemon');
save('device-before.json',before);
const respring=await rpc('system.respring',{force:true});
save('respring.json',respring);
if(!respring.ok)throw Error('The in-flight respring response was not preserved');
let after;
for(let i=0;i<60;i++){
  await sleep(500);
  const reply=await rpc('device.info').catch(error=>({error:String(error)}));
  if(reply.ok&&reply.result.agent.binary_hash===expectedAgent&&reply.result.agent.pid!==before.agent.pid){after=reply.result;break;}
}
if(!after)throw Error('API worker was not recreated automatically');
save('device-after.json',after);
await capture('after');
save('fold-log.json',await checked('files.read',{path:'/var/mobile/Library/Caches/vphone-folddisplay.log',limit:4194304}));
save('environment-after.json',await checked('environment.status'));
console.log(JSON.stringify({workerBefore:before.agent.pid,workerAfter:after.agent.pid,sourceRecovered:true}));
