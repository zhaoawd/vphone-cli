// All calls are restricted to the current integration test VM.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
export const root=fs.realpathSync(new URL('../../../../',import.meta.url));
export const machine=root+'/.build/duo-runtime-84e3ce54/machines/duo-overall-20261116';
export const expectedAgent='612828f62fd75b5f8901c04c47228a18119295849a352c0a1ff08bf41cc13933';
export async function raw(method,params={}) {
    process.chdir(machine);
    return new Promise((resolve,reject)=>{
        const chunks=[],c=net.createConnection('./vphone.sock',()=>c.write(JSON.stringify({t:'rpc',method,params,screen:false})+'\n'));
        c.setTimeout(45000,()=>c.destroy(Error('RPC timeout: '+method)));
        c.on('data',b=>chunks.push(b));c.on('error',reject);
        c.on('end',()=>{try{resolve(JSON.parse(Buffer.concat(chunks)))}catch(e){reject(e)}});
    });
}
export async function rpc(method,params={}) {const r=await raw(method,params);assert(r.ok,JSON.stringify(r));return r.result;}
if(process.argv[1]&&path.resolve(process.argv[1])===new URL(import.meta.url).pathname){
    const [method,params='{}']=process.argv.slice(2);assert(method);
    console.log(JSON.stringify(await raw(method,JSON.parse(params)),null,2));
}
