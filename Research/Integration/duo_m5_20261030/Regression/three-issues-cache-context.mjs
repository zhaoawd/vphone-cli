// Test instance refresh in one script process spanning a render-server restart.
// Keep actual-off fold controls separate from the always-on baseline.
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
    client.setTimeout(90000,()=>client.destroy(Error('RPC timeout')));
    client.on('data',b=>chunks.push(b));client.on('error',reject);
    client.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)));}catch(e){reject(e);}});
});
const checked=async(method,params)=>{const r=await rpc(method,params);if(!r.ok)throw Error(`${method}: ${r.error}`);return r.result;};
save('environment-before.json',await checked('environment.status'));
const device=await checked('device.info');
if(device.agent.binary_hash!=='446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b')throw Error('Unpinned daemon');
save('device.json',device);
await checked('screen.unlock',{timeout:30});
await checked('display.posture',{hinge:'open-flat'});
await sleep(1500);
// The reflection bridge keeps the same CADisplay object alive throughout.
const source=`(function(){
  api('display.modes');
  var ca=ObjC.use('CADisplay');
  function inner(){var ds=ca.displays();for(var i=0;i<ds.count();i++){var d=ds.objectAtIndex_(i);if(d.name()==='VPhone Duo Inner')return d;}throw Error('Inner display absent');}
  function row(d){var u=d.uniqueId();return {id:d.displayId(),uuid:u?u.toString():null,name:d.name(),scale:d.pointScale()};}
  var d=inner(),result={before:row(d)};
  print(JSON.stringify({stage:'before',row:result.before}));
  result.respring=api('system.respring',{force:true});
  sleep(7000);
  result.afterRestart= row(d);
  ca.updateDisplays();
  result.afterClassRefresh=row(inner());
  var signature=d.methodSignatureForSelector_('update');
  if(!signature||signature.numberOfArguments()!==2||signature.methodReturnType()!=='v')throw Error('Unsupported CADisplay.update ABI');
  d.update();
  result.afterInstanceRefresh=row(d);
  result.inventoryAfterInstanceRefresh=row(inner());
  var freshSource="(function(){api('display.modes');var ds=ObjC.use('CADisplay').displays();for(var i=0;i<ds.count();i++){var d=ds.objectAtIndex_(i);if(d.name()==='VPhone Duo Inner'){var u=d.uniqueId();return {id:d.displayId(),uuid:u?u.toString():null};}}throw Error('Inner absent');})()";
  result.freshProcess=api('script.eval',{source:freshSource,timeout:10});
  result.initializers=[];
  for(var name of ['initWithDisplayId:','initWithDisplayID:','_initWithDisplayId:','_initWithDisplayID:']){
    var signature=ca.instanceMethodSignatureForSelector_(name);
    if(!signature)continue;
    var info={name:name,returnType:signature.methodReturnType(),argumentCount:signature.numberOfArguments()};
    if(info.argumentCount===3)info.argumentType=signature.getArgumentTypeAtIndex_(2);
    if(info.returnType==='@'&&info.argumentCount===3&&['I','i','Q','q'].indexOf(info.argumentType)>=0){
      var object=ca.alloc()[name](7);
      if(object)info.display=row(object);
    }
    result.initializers.push(info);
  }
  return result;
})()`;
save('cache-probe-source.json',{source});
save('cache-probe.json',await rpc('script.eval',{source,timeout:30}));
await checked('screen.unlock',{timeout:30});
save('layout-after.json',await checked('display.layout'));
save('environment-after.json',await checked('environment.status'));
console.log('cache probe complete');
