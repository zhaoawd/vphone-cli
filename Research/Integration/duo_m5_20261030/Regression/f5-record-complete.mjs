// Finalize a movie started/stopped through the VM's native Capture menu.
// Keep a single recording epoch even when the same VM records multiple runs.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
const [coldArg,outArg]=process.argv.slice(2);
const root=fs.realpathSync(new URL('../../../../',import.meta.url));
const cold=fs.realpathSync(coldArg),out=fs.realpathSync(outArg);
assert(cold.startsWith(root+'/.build/overall-port-20261116/cold-run.'));
assert(out.startsWith(cold+'/'));
const skip=Number(fs.readFileSync(out+'/log-lines-before.txt','utf8'));assert(Number.isSafeInteger(skip)&&skip>=0);
const log=fs.readFileSync(cold+'/boot.log','utf8').split('\n').slice(skip).join('\n');
const origins=[...log.matchAll(/^\[record\] first frame - uptime_ns=\d+ file=(.+)$/gm)];assert.equal(origins.length,1);
const movie=origins[0][1];assert.equal(path.dirname(movie),cold+'/host-home/Desktop');
assert(path.basename(movie).startsWith('vphone-recording-'));
fs.writeFileSync(out+'/boot.log',log);fs.copyFileSync(movie,out+'/recording.mov');
console.log(JSON.stringify({recording:movie,bytes:fs.statSync(out+'/recording.mov').size,singleRecordingEpoch:true}));
