#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
root="${0:a:h:h:h:h:h}"
cd "$root"
source_cache="$root/.build/duo-next/gles-cache-24A94425"
before_cli="$root/.build/duo-fixes-20261114/baseline/VPhone.bundle/Contents/MacOS/vphone-cli"
after_cli="$root/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli"
out=$(mktemp -d "$root/.build/cache-lifecycle-20261114/cache-compare.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
cp -cR "$source_cache" "$out/before"
cp -cR "$source_cache" "$out/after"
"$before_cli" cfw patch-arm64e-x1-bootstrap-cache "$out/before" --dry-run > "$out/before-plan.log" 2>&1
"$after_cli" cfw patch-arm64e-x1-bootstrap-cache "$out/after" --dry-run > "$out/after-plan.log" 2>&1
cmp "$out/before-plan.log" "$out/after-plan.log"
"$before_cli" cfw patch-dsc-undo-words "$out/before" --undo-log "$out/before/.vphone-dsc-undo.json" > "$out/before-undo.log" 2>&1
"$after_cli" cfw patch-dsc-undo-words "$out/after" --undo-log "$out/after/.vphone-dsc-undo.json" > "$out/after-undo.log" 2>&1
node --input-type=module - "$source_cache" "$out" <<'JS'
import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';import assert from 'node:assert/strict';
const [source,out]=process.argv.slice(2);const files=fs.readdirSync(source).sort();const hash=f=>new Promise((resolve,reject)=>{let h=createHash('sha256');fs.createReadStream(f).on('data',b=>h.update(b)).on('end',()=>resolve(h.digest('hex'))).on('error',reject)});
const manifests={source:{},before:{},after:{}};for(const file of files){const rows=await Promise.all([hash(path.join(source,file)),hash(path.join(out,'before',file)),hash(path.join(out,'after',file))]);for(let i=0;i<3;i++)manifests[['source','before','after'][i]][file]=rows[i];assert.equal(rows[1],rows[2],'Old and new outputs: '+file);if(!file.startsWith('.vphone-dsc-undo'))assert.equal(rows[0],rows[2],'Cache chunk changed: '+file);}
const records=dir=>JSON.parse(fs.readFileSync(path.join(dir,'.vphone-dsc-undo.json'))).Records.filter(r=>!r.PatchID.includes('arm64e_x1'));assert.deepEqual(records(path.join(out,'after')),records(source),'Other patch ownership changed');for(const [name,value]of Object.entries(manifests))fs.writeFileSync(path.join(out,name+'-hashes.json'),JSON.stringify(value,null,2)+'\n');fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({entries:files.length,planningOutputIdentical:true,oldAndNewBytesIdentical:true,cacheChunksUnchanged:true,otherPatchRecordsPreserved:records(source).length},null,2)+'\n');
JS
cat "$out/summary.json"
