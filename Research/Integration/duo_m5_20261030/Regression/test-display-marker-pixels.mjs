import assert from 'node:assert/strict';
import {markerPixels} from './display-marker-pixels.mjs';
const rgba=Buffer.alloc(100*100*4),colors=[[255,0,0],[0,255,0],[0,0,255],[255,255,0]];
const names=['red','green','blue','yellow'];
const probe={fixed:[100,100],markers:names.map((color,i)=>({color,fixed_point:[i%2?80:20,i<2?20:80]}))};
for(const [index,marker] of probe.markers.entries()){
    const [x,y]=marker.fixed_point;
    for(let dy=-5;dy<=5;dy++)for(let dx=-5;dx<=5;dx++){
        const offset=((y+dy)*100+x+dx)*4;for(let c=0;c<3;c++)rgba[offset+c]=colors[index][c];rgba[offset+3]=255;
    }
}
assert(markerPixels(rgba,100,100,probe).every(row=>row.passed));
const shifted={...probe,markers:probe.markers.map((m,i)=>({...m,color:names[(i+1)%4]}))};
assert(markerPixels(rgba,100,100,shifted).every(row=>!row.passed),'Wrong orientation/color labels must fail');
assert(markerPixels(Buffer.alloc(rgba.length),100,100,probe).every(row=>!row.passed),'Blank captures must fail');
assert.throws(()=>markerPixels(Buffer.alloc(4),100,100,probe));
console.log('Marker pixel classifier: correct colors, wrong placement, blank image and invalid size passed');
