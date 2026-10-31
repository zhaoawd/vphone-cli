#!/usr/bin/env python3
"""Independent diagnostic proof; never rewrites native acceptance or VM state.

Only thin Mach-O files with otherwise byte-identical signatures are supported.
CMS verification authenticates content integrity, not publisher trust.
"""
import datetime
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'scripts'))
from patchers import component_signatures as signatures


def node(data,offset=0):
    if offset+2>len(data):raise ValueError('Truncated DER')
    start=offset;tag=data[offset];length=data[offset+1];offset+=2
    if tag&31==31:raise ValueError('Unsupported DER tag')
    if length&128:
        count=length&127
        if not 1<=count<=4 or offset+count>len(data) or data[offset]==0:
            raise ValueError('Invalid DER length')
        length=int.from_bytes(data[offset:offset+count],'big');offset+=count
        if length<128:raise ValueError('Noncanonical DER length')
    end=offset+length
    if end>len(data):raise ValueError('DER exceeds container')
    return (tag,data[offset:end],data[start:end]),end


def children(parent):
    out=[];offset=0
    while offset<len(parent[1]):
        child,offset=node(parent[1],offset);out.append(child)
        if len(out)>128:raise ValueError('Too many DER elements')
    return out


def normalized(cms):
    cms=bytes(cms)
    if len(cms)>1<<20:raise ValueError('CMS too large')
    root,end=node(cms)
    if end!=len(cms) or root[0]!=0x30:raise ValueError('Invalid CMS ContentInfo')
    content=children(root)
    if (len(content)!=2 or content[0][:2]!=(6,bytes.fromhex('2a864886f70d010702'))
            or content[1][0]!=0xa0):raise ValueError('Expected CMS SignedData')
    wrapped=children(content[1])
    if len(wrapped)!=1 or wrapped[0][0]!=0x30:raise ValueError('Invalid SignedData wrapper')
    fields=children(wrapped[0])
    if [f[0] for f in fields]!=[2,0x31,0x30,0xa0,0x31]:
        raise ValueError('Unsupported CMS fields (CRLs/extra fields refused)')
    signers=children(fields[-1])
    if len(signers)!=1 or signers[0][0]!=0x30:raise ValueError('Exactly one signer required')
    signer=children(signers[0])
    if [f[0] for f in signer]!=[2,0x30,0x30,0xa0,0x30,4]:
        raise ValueError('Unsupported signer (unsigned attributes refused)')
    if not signer[5][1]:raise ValueError('Empty CMS signature')
    attributes=[];seen=set();timestamp=None
    for attribute in children(signer[3]):
        if attribute[0]!=0x30:raise ValueError('Invalid CMS attribute')
        parts=children(attribute)
        if len(parts)!=2 or parts[0][0]!=6 or parts[1][0]!=0x31:
            raise ValueError('Invalid CMS attribute value')
        oid=parts[0][1]
        if oid in seen:raise ValueError('Duplicate CMS attribute')
        seen.add(oid)
        if oid==bytes.fromhex('2a864886f70d010905'):
            values=children(parts[1])
            if len(values)!=1 or values[0][0]!=0x17:raise ValueError('Expected one UTC signingTime')
            try:
                timestamp=values[0][1].decode('ascii')
                if len(timestamp)!=13 or not timestamp[:12].isdigit() or timestamp[-1]!='Z':raise ValueError()
                year=int(timestamp[:2]);year+=1900 if year>=50 else 2000
                datetime.datetime.strptime(str(year)+timestamp[2:],'%Y%m%d%H%M%SZ')
            except (ValueError,UnicodeError):raise ValueError('Invalid CMS signingTime') from None
            attributes.append((oid,'verified UTC signingTime'))
        else:attributes.append(attribute[2])
    if timestamp is None:raise ValueError('CMS signingTime missing')
    # Preserve all certificates, algorithms, identity, content, other signed
    # attributes and signature length. Only time and its authenticated signature
    # value may differ, after verifying each original CMS separately.
    return (tuple(f[2] for f in fields[:-1]),tuple(f[2] for f in signer[:3]),
            tuple(attributes),signer[4][2],len(signer[5][1])),timestamp


def cms_region(path):
    layouts=signatures.layouts(path)
    if len(layouts)!=1 or layouts[0]['identity']!='thin' or layouts[0]['signature'] is None:
        raise ValueError('Only signed thin Mach-O supported')
    data=Path(path).read_bytes();start,span=layouts[0]['signature']
    # Existing parser validates all SuperBlob intervals and CodeDirectories.
    signatures.directories(path)
    count=struct.unpack_from('>I',data,start+8)[0];found=[]
    for i in range(count):
        slot,relative=struct.unpack_from('>II',data,start+12+i*8)
        if slot!=0x10000:continue
        magic,length=struct.unpack_from('>II',data,start+relative)
        if magic!=0xfade0b01 or length<=8 or relative+length>span:
            raise ValueError('Invalid CMS signature blob')
        found.append((start+relative+8,length-8))
    if len(found)!=1:raise ValueError('Exactly one CMS wrapper required')
    return found[0]


def verify(path,offset,count):
    data=Path(path).read_bytes();layouts=signatures.layouts(path)
    start,span=layouts[0]['signature'];n=struct.unpack_from('>I',data,start+8)[0]
    primary=None
    for i in range(n):
        slot,relative=struct.unpack_from('>II',data,start+12+i*8)
        if slot==0:
            length=struct.unpack_from('>I',data,start+relative+4)[0]
            primary=data[start+relative:start+relative+length]
    if primary is None:raise ValueError('Missing primary CodeDirectory')
    directories=signatures.directories(path)
    signatures.verify_slots(path,[dict(identity=cd['identity'],slot=cd['slot'],pages=range(cd['count'])) for cd in directories])
    with tempfile.TemporaryDirectory(prefix='t32-cms-verify-') as raw:
        cd=Path(raw)/'CodeDirectory';cd.write_bytes(primary)
        result=subprocess.run(['/usr/bin/openssl','cms','-verify','-binary','-inform','DER',
            '-content',str(cd),'-noverify','-out','/dev/null'],input=data[offset:offset+count],
            capture_output=True,timeout=20)
        if result.returncode:raise ValueError('CMS cryptographic verification failed')
    return sum(cd['count'] for cd in directories)


def compare(first,reapplied):
    first,reapplied=Path(first),Path(reapplied)
    a,b=first.read_bytes(),reapplied.read_bytes();region=cms_region(first)
    if len(a)!=len(b) or cms_region(reapplied)!=region:raise ValueError('File/signature geometry differs')
    offset,count=region;end=offset+count
    if a[:offset]!=b[:offset] or a[end:]!=b[end:]:raise ValueError('Bytes outside CMS differ')
    shape_a,time_a=normalized(a[offset:end]);shape_b,time_b=normalized(b[offset:end])
    if shape_a!=shape_b:raise ValueError('CMS differs beyond signingTime/signature value')
    pages_a=verify(first,*region);pages_b=verify(reapplied,*region)
    if pages_a!=pages_b:raise ValueError('Code page counts differ')
    return dict(firstSHA256=hashlib.sha256(a).hexdigest(),reappliedSHA256=hashlib.sha256(b).hexdigest(),
        exactFileBytesEqual=a==b,qualifiedSignatureTimeDifference=a!=b and time_a!=time_b,
        firstSigningTime=time_a,reappliedSigningTime=time_b,verifiedCodePages=pages_a,
        cmsCryptographicVerification=True,publisherTrustQualified=False,
        runtimeValidated=False,originalNativeAcceptanceChanged=False)


if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: verify_t32_cms_reapplication.py FIRST REAPPLIED')
    print(json.dumps(compare(sys.argv[1],sys.argv[2]),indent=2))
