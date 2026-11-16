// Read-only IMG4/flat DeviceTree audit for the recorded DriverKit state.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const [liveFile,backupFile]=process.argv.slice(2);
function inspect(file){
    const bytes=fs.readFileSync(file);
    function der(offset,end){
        assert(offset+2<=end);const tag=bytes[offset++];let size=bytes[offset++];
        if(size&128){const n=size&127;assert(n>0&&n<=4&&offset+n<=end);size=0;for(let i=0;i<n;i++)size=size*256+bytes[offset++];}
        const limit=offset+size;assert(limit<=end);const item={tag,offset,end:limit};
        if(tag===0x30){item.children=[];for(let p=offset;p<limit;){const c=der(p,limit);item.children.push(c);p=c.end;}}
        return item;
    }
    const top=der(0,bytes.length);assert.equal(top.end,bytes.length);
    function im4p(node){
        if(node.children?.[0]&&bytes.subarray(node.children[0].offset,node.children[0].end).toString()==='IM4P')return node;
        for(const child of node.children??[]){const found=im4p(child);if(found)return found;}
    }
    const image=im4p(top);assert(image);const octet=image.children.find(x=>x.tag===4);assert(octet);
    const data=bytes.subarray(octet.offset,octet.end);let offset=0;
    function node(depth=0){
        assert(depth<128&&offset+8<=data.length);const properties=data.readUInt32LE(offset),children=data.readUInt32LE(offset+4);offset+=8;
        assert(properties<10000&&children<10000);const props={};
        for(let i=0;i<properties;i++){
            assert(offset+36<=data.length);const name=data.subarray(offset,offset+32).toString().split('\0')[0];
            const size=data.readUInt16LE(offset+32),flags=data.readUInt16LE(offset+34);offset+=36;assert(offset+size<=data.length);
            props[name]={hex:data.subarray(offset,offset+size).toString('hex'),flags,string:data.subarray(offset,offset+size).toString().split('\0')[0]};offset+=(size+3)&~3;
        }
        return {props,children:Array.from({length:children},()=>node(depth+1))};
    }
    const tree=node();const product=tree.children.filter(x=>x.props.name?.string==='product');assert.equal(product.length,1);
    return {sha256:createHash('sha256').update(bytes).digest('hex'),model:tree.props.model?.string,driverkit:product[0].props['supports-driverkit']??null};
}
const live=inspect(liveFile),backup=inspect(backupFile);console.log(JSON.stringify({live,backup},null,2));
assert.equal(live.driverkit?.hex,'01000000');assert.equal(live.driverkit?.flags,0);
