import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {setTimeout as sleep} from 'node:timers/promises';
import {rpc,raw,root,expectedAgent} from './followup-567-rpc.mjs';
const [outArg,probeArg,mode='alias-first']=process.argv.slice(2),out=path.resolve(outArg),probe=fs.realpathSync(probeArg);
assert(['alias-first','source-first','inline','debug-alias'].includes(mode));
for(const p of [out,probe])assert(p.startsWith(root+'/.build/'));
fs.mkdirSync(out);const save=(name,value)=>fs.writeFileSync(out+'/'+name+'.json',JSON.stringify(value,null,2)+'\n');
const guest='/var/root/Library/Caches/vphone-debug-'+Date.now().toString(36),jobs=[];
let proxy,startedApp=false;
async function job(suffix,args){
    const label='com.vphone.tests.debug-'+suffix+'-'+Date.now().toString(36),file=guest+'/'+suffix+'.plist';
    const plist={Label:label,ProgramArguments:args,RunAtLoad:true,KeepAlive:false,WorkingDirectory:guest,
        StandardOutPath:guest+'/'+suffix+'.stdout',StandardErrorPath:guest+'/'+suffix+'.stderr'};
    const xml=execFileSync('/usr/bin/plutil',['-convert','xml1','-o','-','-'],{input:JSON.stringify(plist),encoding:'utf8'});
    fs.writeFileSync(out+'/'+suffix+'.plist',xml);await rpc('files.write',{path:file,content:xml});
    await rpc('files.chmod',{path:file,mode:'644'});await rpc('files.chown',{path:file,owner:'0:0'});
    const row={label,file,suffix};jobs.push(row);row.load=await raw('services.load',{paths:[file]});save('jobs',jobs);assert(row.load.ok);
    return row;
}
async function read(file){const r=await rpc('files.read',{path:file,limit:1048576});assert(!r.truncated);return r.content;}
async function lldb(name,pid,commands,localBinary){
    const server=await job(name,['/usr/libexec/debugserver','127.0.0.1:45679','--attach='+pid]);
    await sleep(1500);server.status=await raw('services.status',{label:server.label});save('jobs',jobs);
    const cmds=[];if(localBinary)cmds.push('target create '+localBinary);
    cmds.push('gdb-remote 127.0.0.1:45679',...commands,'process detach');
    fs.writeFileSync(out+'/'+name+'.lldb',cmds.join('\n')+'\n');
    const result=await new Promise(resolve=>{
        const child=spawn('/Applications/Xcode.app/Contents/Developer/usr/bin/lldb',['--batch','--source',out+'/'+name+'.lldb'],{stdio:['ignore','pipe','pipe']});
        const stdout=[],stderr=[];child.stdout.on('data',b=>stdout.push(b));child.stderr.on('data',b=>stderr.push(b));
        const timer=setTimeout(()=>child.kill('SIGTERM'),40000);
        child.on('exit',(code,signal)=>{clearTimeout(timer);resolve({code,signal,stdout:Buffer.concat(stdout).toString(),stderr:Buffer.concat(stderr).toString()});});
    });
    save(name,result);server.stdout=await raw('files.read',{path:guest+'/'+name+'.stdout'});server.stderr=await raw('files.read',{path:guest+'/'+name+'.stderr'});
    server.unload=await raw('services.unload',{paths:[server.file],force:true});save('jobs',jobs);
    return result;
}
const summary={},initial=await rpc('device.info');assert.equal(initial.agent.binary_hash,expectedAgent);
save('device',initial);save('crashes-before',await rpc('logs.crashes'));
try{
    await rpc('files.mkdir',{path:guest});const bytes=fs.readFileSync(probe+'/MutationProbe');
    await rpc('files.write',{path:guest+'/MutationProbe',encoding:'base64',content:bytes.toString('base64')});await rpc('files.chmod',{path:guest+'/MutationProbe',mode:'755'});
    const target=await job('mutation',[guest+'/MutationProbe',guest+'/report.json',...(mode==='inline'?['--inline-only']:mode==='debug-alias'?['--wait-for-debugger']:[])]);
    let report;
    for(let i=0;i<30;i++){await sleep(250);try{report=JSON.parse(await read(guest+'/report.json'));break;}catch{}}
    save('mutation-before',report??{missing:true});
    summary.aliasFirst=report?.original===42&&report.privateAnswer===91&&report.hookAnswer===91&&report.restored===42;
    summary.sourceFirst=report?.original===42&&report.sourceRemap===0&&report.sourceRemapAnswer===91&&report.hookAnswer===91&&report.restored===42;
    summary.inline=report?.original===42&&report.hookAnswer===91&&report.restored===42;
    summary.mode=mode;summary.mutation=mode==='alias-first'?summary.aliasFirst:mode==='source-first'?summary.sourceFirst:summary.inline;
    proxy=spawn('/opt/homebrew/bin/iproxy',['-u','0000FE01-C5A51D613717F61A','-s','127.0.0.1','45679:45679'],{stdio:['ignore','pipe','pipe']});
    const proxyLog=[];proxy.stdout.on('data',b=>proxyLog.push(b));proxy.stderr.on('data',b=>proxyLog.push(b));
    await sleep(500);
    if(report?.pid>1){
        const r=await lldb('lldb-mutation',report.pid,['register read pc','memory read --format d --size 4 --count 1 '+report.debugAddress,
            'memory write --size 4 '+report.debugAddress+' 0x49','memory read --format d --size 4 --count 1 '+report.debugAddress],probe+'/MutationProbe');
        await sleep(500);const after=JSON.parse(await read(guest+'/report.json'));save('mutation-after-debugger',after);
        if(mode==='debug-alias'){
            summary.aliasFirst=after.original===42&&after.privateAnswer===91&&after.hookAnswer===91&&after.restored===42;
            summary.inline=after.original===42&&after.hookAnswer===91&&after.restored===42;
            summary.sourceFirst=after.original===42&&after.sourceRemapAnswer===91&&after.restored===42;
            summary.mutation=summary.aliasFirst;
        }
        summary.debuggerWrite=r.code===0&&after.pid===report.pid&&after.debugValue===73;
        const reset=await lldb('lldb-reset',report.pid,['memory write --size 4 '+report.debugAddress+' 0x29','memory read --format d --size 4 --count 1 '+report.debugAddress],probe+'/MutationProbe');
        await sleep(300);const final=JSON.parse(await read(guest+'/report.json'));save('mutation-restored',final);
        summary.debuggerRestore=reset.code===0&&final.debugValue===41;
    }
    const apps=await rpc('apps.list',{filter:'user'});assert(!apps.truncated);
    let app=apps.apps.find(x=>x.bundle_id==='com.vphone.tests.remap-context');assert(app,'Install the independent context probe first');
    if(!(app.pid>1)){
        await rpc('screen.unlock',{timeout:30});const launch=await rpc('apps.launch',{bundle_id:app.bundle_id});
        app={...app,pid:launch.pid};startedApp=true;save('app-launched',launch);await sleep(500);
    }
    if(app?.pid>1){const r=await lldb('lldb-app',app.pid,['register read pc','thread list','image list -b']);summary.appAttach=r.code===0&&r.stdout.includes('Process ')&&r.stdout.includes('detached');}
    fs.writeFileSync(out+'/iproxy.log',Buffer.concat(proxyLog));
    target.final=await raw('services.status',{label:target.label});save('jobs',jobs);
}finally{
    if(proxy)proxy.kill('SIGTERM');
    for(const row of jobs.toReversed()){
        if(!row.unload)row.unload=await raw('services.unload',{paths:[row.file],force:true});
        row.finalStatus=await raw('services.status',{label:row.label});save('jobs',jobs);
    }
    summary.unloaded=jobs.every(x=>x.unload?.ok&&x.finalStatus?.ok&&x.finalStatus.result.loaded===false);
    if(startedApp){
        save('app-terminated',await raw('apps.terminate',{bundle_id:'com.vphone.tests.remap-context'}));
        const current=await rpc('device.snapshot');if(initial.lock.locked&&!current.lock.locked)await rpc('input.button',{name:'power'});
    }
    save('crashes-after',await rpc('logs.crashes'));save('summary',summary);console.log(JSON.stringify(summary));
}
assert(summary.mutation,'Modified private code and inline hook must execute and restore');
assert(summary.debuggerWrite&&summary.debuggerRestore,'Real LLDB write must be observed by the resumed target and restored');
assert(summary.appAttach,'LLDB must attach to the independent App');
assert(summary.unloaded,'All generated test jobs must be unloaded');
