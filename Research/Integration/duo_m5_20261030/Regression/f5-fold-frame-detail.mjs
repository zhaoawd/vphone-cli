// Inspect the longest repeated interval intersecting an actual fold window.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {alignMovie} from './f5-mov-align.mjs';
import {inspect} from './f5-frame-detail.mjs';
const [root]=process.argv.slice(2);assert(root);
const read=name=>JSON.parse(fs.readFileSync(path.join(root,name)));
const timing=read('movie-timing.json'),samples=path.join(root,'motion/samples');
const trials=fs.readdirSync(samples).filter(n=>/^\d+-\d+-(open|closed)$/.test(n)).map(name=>({name,
    action:read('motion/samples/'+name+'/action.json').action,samples:read('motion/samples/'+name+'/samples.json')}));
const aligned=alignMovie(timing,fs.readFileSync(root+'/boot.log','utf8'),read('motion/samples/clock.json'),trials);
const candidates=aligned.trials.flatMap(trial=>trial.repeats.filter(r=>!r.dark).map(repeat=>({trial:trial.name,repeat})))
    .sort((a,b)=>b.repeat.spanMs-a.repeat.spanMs);assert(candidates.length);
const selected=candidates[0],detail=await inspect(root+'/recording.mov',{...timing,repeats:[selected.repeat]});
console.log(JSON.stringify({trial:selected.trial,...detail},null,2));
