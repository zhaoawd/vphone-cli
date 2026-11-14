import fs from 'node:fs';
import path from 'node:path';
const [root]=process.argv.slice(2);
if(!root)throw Error('Usage: three-issues-check.mjs <baseline samples>');
const summary=JSON.parse(fs.readFileSync(path.join(root,'summary.json')));
const ax=summary.displays.every(row=>row.hits.every(hit=>hit.ok));
const aod=summary.aod.length>1&&summary.aod.every(row=>row.enteredAlwaysOn&&row.remainedAlwaysOn);
const observations=JSON.parse(fs.readFileSync(path.join(root,'aod.json')));
const alwaysOn=s=>s?.lock?.locked&&s.lock.screen_off&&s.blanked===1&&s.panel===1;
const sampledAOD=observations.length===summary.aod.length&&observations.every(row=>
    alwaysOn(row.before)&&alwaysOn(row.after)&&row.samples.length>0&&row.samples.every(alwaysOn));
const capture=summary.displays.every(row=>row.captureAvailable===true);
console.log(JSON.stringify({axHitTestPassed:ax,alwaysOnPreserved:aod&&sampledAOD,
    alwaysOnSamples:observations.reduce((n,row)=>n+row.samples.length,0),nativeCaptureAvailable:capture},null,2));
if(!ax||!aod||!sampledAOD||!capture)process.exitCode=1;
