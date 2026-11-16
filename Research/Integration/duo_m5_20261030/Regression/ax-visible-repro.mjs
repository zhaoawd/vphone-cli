// Minimized visibility regression: the nine App-owned buttons must all be discoverable.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {setTimeout as sleep} from 'node:timers/promises';
const [socketArg,outArg,expectedAgent]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const socket=fs.realpathSync(socketArg),out=path.resolve(outArg);
assert.equal(path.dirname(socket),root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116');
assert(out.startsWith(root+'/.build/'));assert(/^[a-f0-9]{64}$/.test(expectedAgent??''));
fs.mkdirSync(out);process.chdir(path.dirname(socket));
const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
    c.setTimeout(30000,()=>c.destroy(Error('RPC timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);
    c.on('end',()=>{try{const r=JSON.parse(Buffer.concat(chunks));assert(r.ok,JSON.stringify(r));resolve(r.result)}catch(e){reject(e)}});
});
assert.equal((await rpc('device.info')).agent.binary_hash,expectedAgent);
const before={pose:await rpc('display.pose'),lock:await rpc('display.auto_lock')};save('before',before);
try{
    await rpc('display.auto_lock.set',{never:true});await rpc('screen.unlock',{timeout:30});
    await rpc('display.posture',{hinge:'open-flat'});await rpc('display.rotation',{orientation:'portrait'});
    await rpc('apps.launch',{bundle_id:'com.autophone.tap-probe'});await sleep(1200);
    const foreground=await rpc('apps.foreground');save('foreground',foreground);
    assert(foreground.verified&&foreground.bundle_id==='com.autophone.tap-probe');
    const apps=await rpc('apps.list',{filter:'user'});assert.equal(apps.truncated,false);
    const app=apps.apps.find(a=>a.bundle_id===foreground.bundle_id);assert(app?.data_path);
    const probe=JSON.parse((await rpc('files.read',{path:app.data_path+'/Documents/tap-probe.json'})).content);save('probe',probe);
    save('layout',await rpc('display.layout'));
    const rows=[];
    for(let sample=0;sample<3;sample++){
        const all=await rpc('ui.tree',{visible_only:false}),visible=await rpc('ui.tree');
        const allIDs=all.elements.filter(e=>/^tap-\d$/.test(e.identifier)).map(e=>e.identifier).sort();
        const visibleIDs=visible.elements.filter(e=>/^tap-\d$/.test(e.identifier)).map(e=>e.identifier).sort();
        rows.push({sample,all,visible,allIDs,visibleIDs});save('samples',rows);
        assert.equal(allIDs.length,9,'Unfiltered AX must contain the nine App buttons');
    }
    const summary={samples:rows.length,unfilteredCounts:rows.map(r=>r.allIDs.length),visibleCounts:rows.map(r=>r.visibleIDs.length)};
    save('summary',summary);console.log(JSON.stringify(summary));
    for(const row of rows)assert.deepEqual(row.visibleIDs,row.allIDs,'Default AX query omitted visible inner-panel buttons');
}finally{
    save('auto-lock-restored',await rpc('display.auto_lock.set',before.lock.never?{never:true}:{seconds:before.lock.auto_lock_seconds}));
    save('pose-restored',await rpc('display.posture',{hinge:before.pose.hinge,orientation:before.pose.orientation,tabletop:before.pose.tabletop}));
    await rpc('input.button',{name:'home'});
}
