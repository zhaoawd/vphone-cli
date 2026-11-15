// Scoped regression for the 2026-11-15 isolated VM; never targets a library default.
import {fileURLToPath} from 'node:url';
import fs from 'node:fs';import path from 'node:path';import net from 'node:net';import http from 'node:http';import assert from 'node:assert/strict';import {setTimeout as sleep} from 'node:timers/promises';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../..');
const dir=root+'/.build/host-webcam-distribution-20261115';
const session=fs.realpathSync(fs.readFileSync(dir+'/active-mixed-session.txt','utf8').trim());
assert.equal(path.dirname(session),fs.realpathSync(dir));
assert(path.basename(session).startsWith('mixed-session.'));
const [mode='read',arg]=process.argv.slice(2),bundle='com.vphone.tests.camera-web';
process.chdir(root+'/.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-20261115');
const raw=(method,params={})=>new Promise((resolve,reject)=>{let chunks=[];const c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));c.setTimeout(60000,()=>c.destroy(Error('timeout')));c.on('data',b=>chunks.push(b));c.on('error',reject);c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}})});
const rpc=async(m,p)=>{let r=await raw(m,p);assert.equal(r.ok,true,m+': '+JSON.stringify(r.error));return r.result;};
const save=(name,data)=>fs.writeFileSync(session+'/'+name+'.json',JSON.stringify(data,null,2)+'\n');assert.equal((await rpc('device.info')).agent.binary_hash,'446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b');
async function upload(file,target){const log=fs.readFileSync(session+'/boot.log','utf8'),base=log.match(/^\[api\] HTTP\/WebSocket API: (http:\/\/127\.0\.0\.1:\d+)$/m)?.[1],token=log.match(/^\[api\] token: ([a-f0-9]{64})$/m)?.[1];assert(base&&token);const endpoint=new URL('/v1/files/content',base);endpoint.searchParams.set('path',target);return new Promise((resolve,reject)=>{const req=http.request(endpoint,{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/octet-stream','Content-Length':fs.statSync(file).size}},res=>{const chunks=[];res.on('data',b=>chunks.push(b));res.on('end',()=>{try{assert.equal(res.statusCode,200);resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}})});req.on('error',reject);fs.createReadStream(file).pipe(req);});}
if(mode==='install'||mode==='update'){const apps=await rpc('apps.list',{filter:'all'});save('apps-before-probe',apps);assert.equal(apps.apps.some(a=>a.bundle_id===bundle),mode==='update','Only the generated fixture may be updated');save('probe-upload',await upload(dir+'/probe/CameraWebProbe.ipa','/var/root/Library/Caches/vphone-camera-regression.ipa'));save('probe-install',await rpc('apps.install',{path:'/var/root/Library/Caches/vphone-camera-regression.ipa'}));await rpc('screen.unlock',{timeout:30});await rpc('display.posture',{hinge:'closed'});save('probe-launch',await rpc('apps.launch',{bundle_id:bundle}));await sleep(1500);save('probe-data-dir',await rpc('apps.data_dir',{bundle_id:bundle}));}
if(mode==='tree'){const tree=await rpc('ui.tree');save(arg??'probe-tree',tree);console.log(JSON.stringify({foreground:await rpc('apps.foreground'),elements:tree.elements}));}
if(mode==='tap'){const p=arg.startsWith('probe.')?{identifier:arg}:{text:arg,match:'exact'};save('probe-tap-'+Date.now(),await rpc('ui.tap_element',p));await sleep(500);}
if(mode==='read'){const {data_path}=await rpc('apps.data_dir',{bundle_id:bundle});const r=await rpc('files.read',{path:data_path+'/Documents/report.json',limit:65536});const report=JSON.parse(r.content);save(arg??'probe-report',report);console.log(JSON.stringify(report));}
if(mode==='rpc'){const [method,params]=JSON.parse(arg);const r=await raw(method,params);save('probe-rpc-'+Date.now(),r);console.log(JSON.stringify(r));}
if(mode==='install'||mode==='update')console.log('Installed and launched isolated camera fixture');
if(mode==='accept'||mode==='safari') {
 const environment=await rpc('environment.status');
 const original=JSON.parse(fs.readFileSync(dir+'/original-cache-state.json','utf8')).environment;
 assert.equal(environment.root_read_only,true);
 assert.equal(environment.libraries.length,21);
 const expected=original.libraries.map(l=>({...l,sha256:l.name==='SystemHook-vphone.dylib'?'6aa02df8eacfe8d94fd85ea6cf701e8d612f29b018c9407deb4d7bc0dde28217':l.sha256}));
 assert.deepEqual(environment.libraries,expected);
 save('camera-regression-environment',environment);
}
if(mode==='accept') {
 const outcome={};save('camera-accept-environment',await rpc('environment.status'));
 const running=(await rpc('processes.list',{filter:'CameraWebProbe'})).processes;
 if(running.some(p=>p.name==='CameraWebProbe'))await rpc('apps.terminate',{bundle_id:bundle});
 await rpc('screen.unlock',{timeout:30});await rpc('display.posture',{hinge:'closed'});await rpc('apps.launch',{bundle_id:bundle});await sleep(1500);
 const data=await rpc('apps.data_dir',{bundle_id:bundle});
 const report=async()=>JSON.parse((await rpc('files.read',{path:data.data_path+'/Documents/report.json',limit:65536})).content);
 const wait=async(key,test)=>{for(let i=0;i<80;i++){await sleep(250);const r=await report();save('camera-accept-progress',r);if(test(r[key]))return r;if(r[key]?.phase==='error'||r[key]?.phase==='terminated')throw Error(key+': '+JSON.stringify(r[key]));}throw Error('Timed out: '+key);};
 const tap=async identifier=>rpc('ui.tap_element',{identifier});
 await tap('probe.native.start');outcome.native=(await wait('native',r=>r?.frames>=10&&r.unique>=3)).native;save('camera-accept-native',outcome.native);
 await tap('probe.native.stop');await tap('probe.web.open');await wait('wk',r=>r?.phase==='ready'&&r.secure===true);
 await rpc('ui.tap_element',{text:'Start Web Camera',match:'exact'});outcome.wk=(await wait('wk',r=>r?.frames>=10&&r.unique>=3)).wk;save('camera-accept-webkit',outcome.wk);
 save('camera-accept-summary',outcome);console.log(JSON.stringify(outcome));
}
if(mode==='safari') {
 const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');const run=promisify(execFile);let screenCounter=0;
 const modal=async()=>{
   const capture=await rpc('display.capture_active');assert.equal(capture.source.display_id,1);assert.equal(capture.rotation_applied,0);const scale=capture.source.point_scale;assert.equal(scale,3);
   const file=session+'/safari-step-'+screenCounter++ +'.png';fs.writeFileSync(file,Buffer.from(capture.base64,'base64'));const {stdout}=await run(dir+'/read-screen-text',[file]);const words=JSON.parse(stdout).text;save('safari-ocr-'+screenCounter,words);
   const normalized=words.map(w=>({...w,text:w.text.replaceAll('’',"'").replaceAll('“','"').replaceAll('”','"')}));const text=normalized.map(w=>w.text).join(' ');let target;
   if(/Trust This Computer/i.test(text))target=normalized.find(w=>/^Don't Trust$/i.test(w.text));
   else if(/camera/i.test(text)&&(/127\.0\.0\.1|localhost/.test(text)||/Camera Regression/.test(text)))target=normalized.find(w=>/^Allow$/i.test(w.text));
   if(!target)return false;assert(target.confidence>=0.8);assert(target.pixel_x>0&&target.pixel_x<capture.width&&target.pixel_y>0&&target.pixel_y<capture.height);save('safari-modal-'+screenCounter,{text:target.text,x:target.pixel_x/scale,y:target.pixel_y/scale});await rpc('input.tap',{x:target.pixel_x/scale,y:target.pixel_y/scale});await sleep(250);return true;
 };
 await rpc('screen.unlock',{timeout:30});await rpc('display.posture',{hinge:'closed'});await rpc('apps.launch',{bundle_id:bundle});await sleep(1500);for(let i=0;i<3;i++){if(!await modal())break;}
 await rpc('ui.tap_element',{identifier:'probe.safari.open'});await sleep(1500);for(let i=0;i<3;i++){if(!await modal())break;}
 assert.equal((await rpc('apps.foreground')).bundle_id,'com.apple.mobilesafari');save('safari-action',await rpc('ui.tap_element',{text:'Start Web Camera',match:'exact'}));
 let passed;for(let i=0;i<35;i++){await sleep(250);const tree=await raw('ui.tree');save('safari-tree-latest',tree);for(const element of tree.result?.elements??[]){try{const value=JSON.parse(element.label);if(value.client==='safari'){save('safari-dom-latest',value);if(value.phase==='error')throw Error('Web camera error '+JSON.stringify(value));if(value.frames>=10&&value.unique>=3&&value.secure===true)passed=value;}}catch(e){if(e.message.startsWith('Web camera error'))throw e;}}
   if(passed)break;if(i%4===0)await modal();
 }
 assert(passed,'Safari must deliver 10 changing frames, not merely acknowledge a click');save('safari-accept-summary',passed);console.log(JSON.stringify(passed));
}
if(mode==='snapshot') {
 const files=await rpc('files.list',{path:'/var/mobile'}),apps=await rpc('apps.list',{filter:'all'}),services=await rpc('services.list');const expected={files:files.entries.length,apps:apps.apps.length,services:services.services.length};save('gui-rpc-expected',expected);save('gui-rpc-lists',{files,apps,services});console.log(JSON.stringify(expected));
}
