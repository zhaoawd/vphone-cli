// Uses the target's existing CoreDevice pairing. It never pairs/unpairs a host.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {setTimeout as sleep} from 'node:timers/promises';
import {rpc,raw,root,expectedAgent} from './followup-567-rpc.mjs';
const [outArg]=process.argv.slice(2),out=path.resolve(outArg);assert(out.startsWith(root+'/.build/'));fs.mkdirSync(out);
const save=(n,v)=>fs.writeFileSync(out+'/'+n+'.json',JSON.stringify(v,null,2)+'\n');
const udid='0000FE01-C5A51D613717F61A',name='com.vphone.tests.pairing.'+Date.now().toString(36);
const device=await rpc('device.info');assert.equal(device.agent.binary_hash,expectedAgent);save('device',device);
const image=await rpc('files.read',{path:'/usr/libexec/remotepairingdeviced',binary:true,limit:8*1024*1024});assert(!image.truncated);
save('pairing-image',{sha256:createHash('sha256').update(Buffer.from(image.content,'base64')).digest('hex')});
const trace=raw('logs.syslog',{seconds:15,max_lines:500,process:'remotepairingdeviced'});
const child=spawn('/usr/bin/xcrun',['devicectl','device','notification','observe','--device',udid,'--name',name,
    '--session-timeout','12','--timeout','20','--json-output',out+'/notifications.json'],{stdio:['ignore','pipe','pipe']});
let stdout='',stderr='',code,signal;child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
const done=new Promise(resolve=>child.on('exit',(c,s)=>{code=c;signal=s;resolve();}));
try{
    for(let i=0;i<60&&!stdout.includes('observation started')&&code===undefined;i++)await sleep(250);
    assert(stdout.includes('observation started'),'A real remote notification subscription is required');
    const posts=[];for(let i=1;i<=3;i++){posts.push(await rpc('notify.post',{name,state:i}));await sleep(600);}save('posts',posts);
    await done;
    fs.writeFileSync(out+'/observe.stdout',stdout);fs.writeFileSync(out+'/observe.stderr',stderr);
    save('observe-exit',{code,signal});
    const details=execFileSync('/usr/bin/xcrun',['devicectl','device','info','details','--device',udid,'--timeout','20','--json-output',out+'/details.json'],{encoding:'utf8',timeout:25000});
    fs.writeFileSync(out+'/details.log',details);
    const detailsJSON=JSON.parse(fs.readFileSync(out+'/details.json'));assert.equal(detailsJSON.info.outcome,'success');
    const result=detailsJSON.result;assert.equal(result.hardwareProperties.udid,udid);assert.equal(result.connectionProperties.tunnelState,'connected');
    const notifications=stdout.split('\n').filter(line=>line.includes("Observed '"+name+"'")).length;
    save('summary',{code,udid,name,tunnelAddress:result.connectionProperties.tunnelIPAddress,stdout,posts:posts.length,notifications});
    assert.equal(code,0);assert.equal(notifications,3,'All three guest-origin notifications must arrive over the subscribed protocol');
}finally{
    if(code===undefined)child.kill('SIGTERM');
    fs.writeFileSync(out+'/observe.stdout',stdout);fs.writeFileSync(out+'/observe.stderr',stderr);
    save('guest-log',await trace);
}
console.log(JSON.stringify({coreDeviceProtocol:true,guestNotificationRoundTrip:true,lockdownPairingValidated:false}));
