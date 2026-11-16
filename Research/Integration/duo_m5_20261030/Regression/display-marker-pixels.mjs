import assert from 'node:assert/strict';
export function markerPixels(rgba,width,height,probe){
    assert.equal(rgba.length,width*height*4);
    assert(probe.fixed.every(v=>Number.isFinite(v)&&v>0));
    return probe.markers.map(marker=>{
        const x=Math.round(marker.fixed_point[0]*width/probe.fixed[0]);
        const y=Math.round(marker.fixed_point[1]*height/probe.fixed[1]);
        assert(x>=3&&x<width-3&&y>=3&&y<height-3);
        const rgb=[0,0,0];let n=0;
        for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++){
            const index=((y+dy)*width+x+dx)*4;for(let c=0;c<3;c++)rgb[c]+=rgba[index+c];n++;
        }
        for(let c=0;c<3;c++)rgb[c]/=n;
        const [r,g,b]=rgb;
        const observed=r>190&&g<80&&b<80?'red':g>190&&r<80&&b<80?'green':
            b>190&&r<80&&g<80?'blue':r>190&&g>190&&b<80?'yellow':'other';
        return {color:marker.color,pixel:[x,y],rgb,observed,passed:observed===marker.color};
    });
}
