// Observe the existing App spawn failure without changing its signature or policy.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(45000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
assert.equal((await rpc('device.info')).agent.binary_hash,expectedAgent);
const id='com.vphone.tests.remap-probe',apps=await rpc('apps.list',{filter:'user'});
assert.equal(apps.truncated,false);const app=apps.apps.find(a=>a.bundle_id===id);assert(app?.data_path);save('app',app);
await rpc('screen.unlock',{timeout:30});if(app.pid>0)save('terminate',await rpc('apps.terminate',{bundle_id:id}));
const capture=rpc('logs.syslog',{seconds:10,max_lines:2000,message_contains:'RemapProbe'}).then(result=>({result}),error=>({error:String(error)}));
await sleep(500);const launch=await rpc('apps.launch',{bundle_id:id});save('launch',launch);
let report;
for(let attempt=0;attempt<40;attempt++){
    await sleep(250);try{
        const file=await rpc('files.read',{path:app.data_path+'/Documents/remap-probe.json'});
        const value=JSON.parse(file.content);if(value.pid===launch.pid){report=value;save('report',report);if(report.complete)break;}
    }catch(error){save('read-error',{error:String(error)});}
}
save('unified-log',await capture);assert(report?.complete&&report.pid===launch.pid,'Fresh complete probe required');
save('summary',{pid:report.pid,remaps:report.cases.length,passed:report.cases.filter(c=>c.passed).length,standalone:report.standalone});
console.log(JSON.stringify({pid:report.pid,standalone:report.standalone}));
assert(report.standalone.every(row=>row.spawnError===0&&row.exit===0),'App direct spawn remains a failing acceptance condition');
