import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';
const root=path.resolve(import.meta.dirname,'../../../../');
const [sourceArg,outArg]=process.argv.slice(2);
if(!sourceArg||!outArg)throw Error('Usage: node copy-standalone-inputs.mjs <System root> <new output directory>');
const source=path.resolve(sourceArg),out=path.resolve(outArg);
if(!out.startsWith(root+'/.build/')||fs.existsSync(out))throw Error('Output must be a new directory under this checkout .build');
const code=fs.readFileSync(root+'/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareGuestSystemPatchSet.swift','utf8');
const block=code.slice(code.indexOf('public static let arm64eX1AccessibilityImages:'),code.indexOf('public static let arm64eX1OptionalImages'));
const names=[...block.matchAll(/\("system-[^"]+", "([^"]+)"\)/g)].map(x=>x[1]);names.push('SpringBoardHomePopAccessibility');
fs.mkdirSync(out,{recursive:true});const inventory=[];const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
for(const name of names){const bundle='System/Library/AccessibilityBundles/'+name+'.axbundle',p=bundle+'/'+name;if(!fs.existsSync(source+'/'+p)){inventory.push({path:p,present:false});continue;}fs.mkdirSync(path.dirname(out+'/'+bundle),{recursive:true});fs.cpSync(source+'/'+bundle,out+'/'+bundle,{recursive:true,dereference:false,preserveTimestamps:true});inventory.push({path:p,present:true,live_sha256:hash(source+'/'+p),backup_sha256:fs.existsSync(source+'/'+p+'.bak')?hash(source+'/'+p+'.bak'):null});}
const pairing='usr/libexec/remotepairingdeviced';fs.mkdirSync(path.dirname(out+'/'+pairing),{recursive:true});fs.copyFileSync(source+'/'+pairing,out+'/'+pairing);inventory.push({path:pairing,present:true,live_sha256:hash(source+'/'+pairing)});
fs.writeFileSync(out+'/inventory.json',JSON.stringify({source,images:inventory},null,2)+'\n');console.log(JSON.stringify({targets:names.length,present:inventory.filter(x=>x.present).length,out}));
