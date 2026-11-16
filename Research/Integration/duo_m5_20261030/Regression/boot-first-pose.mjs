// Measure the first pose read/reapply immediately after the first successful RPC.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
const [socketArg,outArg,expected,mode]=process.argv.slice(2);
assert(mode===undefined||mode==='--transition');
const root=fs.realpathSync(new URL('../../../../',import.meta.url)),socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const start=process.hrtime.bigint(),now=()=>Number(process.hrtime.bigint()-start)/1e6,rows=[];
async function rpc(method,params={}){
    const row={method,params,sent:now()};rows.push(row);
    try{
        const reply=await new Promise((resolve,reject)=>{
            const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
            c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
            c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
        });row.reply=reply;assert(reply.ok,JSON.stringify(reply));return reply.result;
    }catch(error){row.error=String(error);throw error;}
    finally{row.received=now();row.elapsed=row.received-row.sent;save('requests',rows);}
}
try{
    const device=await rpc('device.info');save('device-before',device);assert.equal(device.agent.binary_hash,expected);
    const before=await rpc('display.pose');save('pose-before',before);
    let transitionObserved=false;
    try{
        const params=mode?{hinge:'open-flat',orientation:'portrait'}:{hinge:before.hinge,orientation:before.orientation,tabletop:before.tabletop};
        if(mode)assert.equal(before.hinge,1,'Closed initial pose is required for the transition control');
        const after=await rpc('display.posture',params);save('first-posture',after);
        if(mode){const changed=await rpc('display.pose');save('pose-expanded',changed);assert.notEqual(changed.hinge,before.hinge);transitionObserved=true;}
    }finally{
        if(mode)save('pose-restored',await rpc('display.posture',{hinge:before.hinge,orientation:before.orientation,tabletop:before.tabletop}));
    }
    const actual=await rpc('display.pose');save('pose-after',actual);
    for(const key of ['hinge','orientation','tabletop'])assert.equal(actual[key],before[key]);
    save('summary',{passed:true,bootUUID:device.boot_session_uuid,firstRPCUptime:device.uptime_seconds,
        firstPoseReadMs:rows[1].elapsed,firstPostureMs:rows[2].elapsed,poseUnchanged:true,mode:mode?'transition':'reapply',transitionObserved});
}catch(error){save('failure',{error:String(error)});throw error;}
