"""Bounded Mach-O/DSC signature structure and final code-page verification.

Uses the producer's LC_CODE_SIGNATURE / dyld header and SuperBlob /
CodeDirectory format. Evidence proves byte relationships, not signer trust.
"""
import hashlib
import os
import stat
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile


def read(stream, offset, count, limit):
    if offset<0 or count<0 or offset+count>limit: raise ValueError('signature read outside file')
    stream.seek(offset);data=stream.read(count)
    if len(data)!=count: raise ValueError('truncated signature data')
    return data


def layouts(path):
    from .component_effects import regular
    size=Path(path).stat().st_size
    with regular(path) as f:
        magic=read(f,0,min(size,16),size)
        if magic.startswith(b'dyld_'):
            offset,count=struct.unpack('<QQ',read(f,0x28,16,size))
            return [dict(base=0,size=size,identity='dsc',signature=(offset,count),commands=[],end=0,header=b'')]
        slices=[(0,size,'thin')]
        if magic[:4] in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
            count=struct.unpack('>I',magic[4:8])[0]
            if not 0<count<=32: raise ValueError('invalid fat architecture count')
            wide=magic[:4]==b'\xca\xfe\xba\xbf';width=32 if wide else 20;slices=[]
            for index in range(count):
                row=read(f,8+index*width,width,size)
                cpu,sub,offset,length,align=struct.unpack('>IIQQI' if wide else '>IIIII',row[:28] if wide else row)
                if offset+length>size or offset<8+count*width or align>30 or offset%(1<<align) or length<32:
                    raise ValueError('invalid fat slice')
                if any(offset<old+span and old<offset+length for old,span,_ in slices): raise ValueError('overlapping fat slices')
                slices.append((offset,length,f'{cpu}:{sub}'))
            if len({identity for _,_,identity in slices})!=len(slices): raise ValueError('duplicate fat architecture')
        result=[]
        for base,length,identity in slices:
            header=read(f,base,32,size)
            if header[:4]!=b'\xcf\xfa\xed\xfe': raise ValueError('unsupported signing container')
            if identity!='thin' and identity!='%d:%d'%struct.unpack_from('<II',header,4):
                raise ValueError('fat architecture differs from slice header')
            ncmds,command_size=struct.unpack_from('<II',header,16)
            if command_size>16<<20 or ncmds>65536 or 32+command_size>length: raise ValueError('invalid signing load commands')
            commands=read(f,base+32,command_size,size);position=0;normalized=[];signature=None;linkedit=None
            for _ in range(ncmds):
                if position+8>len(commands): raise ValueError('truncated signing command')
                cmd,count=struct.unpack_from('<II',commands,position)
                if count<8 or position+count>len(commands): raise ValueError('invalid signing command')
                raw=bytearray(commands[position:position+count])
                if cmd==0x1d:
                    if count!=16 or signature is not None: raise ValueError('ambiguous signature command')
                    start,span=struct.unpack_from('<II',raw,8)
                    if start+span>length or start<32+command_size: raise ValueError('invalid signature bounds')
                    signature=(base+start,span)
                else:
                    if cmd==0x19 and raw[8:24].rstrip(b'\0')==b'__LINKEDIT':
                        if count!=72 or linkedit is not None: raise ValueError('invalid linkedit command')
                        linkedit=struct.unpack_from('<QQQ',raw,32)
                        raw[32:40]=b'\0'*8;raw[48:56]=b'\0'*8
                    normalized.append(bytes(raw))
                position+=count
            if position!=command_size: raise ValueError('load command size differs')
            masked=header[:16]+b'\0'*8+header[24:]
            result.append(dict(base=base,size=length,identity=identity,signature=signature,commands=normalized,end=32+command_size,header=masked,linkedit=linkedit))
        return result


def directories(path):
    from .component_effects import regular
    size=Path(path).stat().st_size;result=[]
    with regular(path) as f:
        for layout in layouts(path):
            if layout['signature'] is None: continue
            start,span=layout['signature'];head=read(f,start,12,size)
            magic,length,count=struct.unpack('>III',head)
            if magic!=0xfade0cc0 or length>span or count>256 or length<12+count*8: raise ValueError('invalid signature SuperBlob')
            slots=set(); intervals=[]
            for index in range(count):
                slot,offset=struct.unpack('>II',read(f,start+12+index*8,8,size))
                if slot in slots: raise ValueError('duplicate signature slot')
                slots.add(slot)
                if offset<12+count*8 or offset+8>length: raise ValueError('invalid signature blob offset')
                tag,blob_size=struct.unpack('>II',read(f,start+offset,8,size))
                if blob_size<8 or offset+blob_size>length: raise ValueError('invalid signature blob length')
                if any(offset<end and beginning<offset+blob_size for beginning,end in intervals):
                    raise ValueError('overlapping signature blobs')
                intervals.append((offset,offset+blob_size))
                if slot==0 or 0x1000<=slot<0x1006:
                    if tag!=0xfade0c02: raise ValueError('invalid CodeDirectory slot')
                elif tag==0xfade0c02: raise ValueError('CodeDirectory in wrong signature slot')
                if tag!=0xfade0c02: continue
                cd=start+offset;raw=read(f,cd,min(blob_size,64),size)
                if len(raw)<44: raise ValueError('truncated CodeDirectory')
                version,hash_offset,nslots,limit=struct.unpack_from('>I',raw,8)[0],struct.unpack_from('>I',raw,16)[0],struct.unpack_from('>I',raw,28)[0],struct.unpack_from('>I',raw,32)[0]
                hash_size,hash_type,page_power=raw[36],raw[37],raw[39]
                if version>=0x20300 and limit==0 and len(raw)>=64: limit=struct.unpack_from('>Q',raw,56)[0]
                minimum=44
                for threshold,header_size in [(0x20100,48),(0x20200,52),(0x20300,64),(0x20400,88),(0x20500,96),(0x20600,108)]:
                    if version>=threshold: minimum=header_size
                special=struct.unpack_from('>I',raw,24)[0]
                if version>0x20600 or blob_size<minimum or hash_offset-special*hash_size<minimum:
                    raise ValueError('invalid CodeDirectory header/hash bounds')
                if version>=0x20100 and struct.unpack_from('>I',raw,44)[0]:
                    raise ValueError('unsupported CodeDirectory scatter mapping')
                if not 0<page_power<=20 or not 0<hash_size<=64 or hash_offset+nslots*hash_size>blob_size or limit>layout['size'] or limit>start-layout['base']:
                    raise ValueError('invalid CodeDirectory table bounds')
                page_size=1<<page_power
                if nslots!=(limit+page_size-1)//page_size: raise ValueError('CodeDirectory page count differs')
                result.append(dict(identity=layout['identity'],slot=slot,base=layout['base'],table=cd+hash_offset,
                                   count=nslots,limit=limit,pageSize=page_size,hashSize=hash_size,hashType=hash_type))
    return result


def slot_ranges(path):
    return [(cd['table'],cd['table']+cd['count']*cd['hashSize']) for cd in directories(path)]


def changed_slots(before, after, spans):
    required=[]
    for cd in directories(after):
        pages=set()
        for offset,count in spans:
            low=max(offset,cd['base']);high=min(offset+count,cd['base']+cd['limit'])
            if low<high: pages.update(range((low-cd['base'])//cd['pageSize'],(high-cd['base']-1)//cd['pageSize']+1))
            low=max(offset,cd['table']);high=min(offset+count,cd['table']+cd['count']*cd['hashSize'])
            if low<high: pages.update(range((low-cd['table'])//cd['hashSize'],(high-cd['table']-1)//cd['hashSize']+1))
        if pages: required.append(dict(identity=cd['identity'],slot=cd['slot'],pages=sorted(pages)))
    return required


def verify_slots(path, requirements):
    from .component_effects import regular
    cds=directories(path);size=Path(path).stat().st_size
    with regular(path) as f:
        for requirement in requirements:
            matches=[cd for cd in cds if cd['identity']==requirement['identity'] and cd['slot']==requirement['slot']]
            if len(matches)!=1: raise ValueError('required final CodeDirectory missing')
            cd=matches[0]
            algorithm={1:'sha1',2:'sha256'}.get(cd['hashType'])
            if algorithm is None: raise ValueError('unsupported final CodeDirectory hash')
            for page in requirement['pages']:
                if not 0<=page<cd['count']: raise ValueError('required final code page missing')
                start=page*cd['pageSize'];count=min(cd['pageSize'],cd['limit']-start)
                wanted=hashlib.new(algorithm,read(f,cd['base']+start,count,size)).digest()
                if len(wanted)!=cd['hashSize'] or read(f,cd['table']+page*cd['hashSize'],cd['hashSize'],size)!=wanted:
                    raise ValueError('final CodeDirectory page hash differs')


def entitlements(path):
    directories(path)
    from .component_effects import regular
    size=Path(path).stat().st_size;result=[]
    with regular(path) as f:
        for layout in layouts(path):
            if layout['signature'] is None: raise ValueError('missing final signature')
            start,span=layout['signature'];magic,length,count=struct.unpack('>III',read(f,start,12,size))
            if magic!=0xfade0cc0 or length>span or count>256: raise ValueError('invalid final signature')
            matches=[]
            for index in range(count):
                slot,offset=struct.unpack('>II',read(f,start+12+index*8,8,size))
                if slot!=5: continue
                tag,blob_size=struct.unpack('>II',read(f,start+offset,8,size))
                if tag!=0xfade7171 or blob_size<8 or blob_size>16<<20 or offset+blob_size>length: raise ValueError('invalid entitlement blob')
                matches.append(plistlib.loads(read(f,start+offset+8,blob_size-8,size)))
            if len(matches)>1: raise ValueError('ambiguous entitlements')
            result.append(matches[0] if matches else {})
    return result


def verify_signing(before, after):
    from .component_effects import regular, CHUNK
    old,new=layouts(before),layouts(after)
    directories(before)
    if len(old)!=len(new): raise ValueError('signing changed architecture count')
    with regular(before) as a,regular(after) as b:
        for left,right in zip(old,new):
            if left['identity']!=right['identity'] or left['identity']=='dsc' or left['header']!=right['header'] or left['commands']!=right['commands']:
                raise ValueError('signing changed executable headers')
            if right['signature'] is None: raise ValueError('signer produced no signature')
            for stream,row,path in [(a,left,before),(b,right,after)]:
                if row.get('linkedit') is not None:
                    vmsize,fileoff,filesize=row['linkedit']
                    end=row['size'] if row['signature'] is None else sum(row['signature'])-row['base']
                    if fileoff+filesize!=end or vmsize not in {((filesize+page-1)//page)*page for page in (4096,16384)}:
                        raise ValueError('linkedit sizes do not describe actual signature layout')
                if row['signature'] is not None:
                    position=sum(row['signature']);end=row['base']+row['size']
                    while position<end:
                        count=min(CHUNK,end-position)
                        if any(read(stream,position,count,Path(path).stat().st_size)):
                            raise ValueError('non-signature trailer cannot be excluded')
                        position+=count
            start=max(left['end'],right['end'])
            for stream,row,path in [(a,left,before),(b,right,after)]:
                if row['end']<start and any(read(stream,row['base']+row['end'],start-row['end'],Path(path).stat().st_size)):
                    raise ValueError('signature load command overwrote non-padding bytes')
            ends=[row['signature'][0]-row['base'] if row['signature'] else row['size'] for row in (left,right)]
            position=start
            while position<min(ends):
                count=min(CHUNK,min(ends)-position)
                if read(a,left['base']+position,count,Path(before).stat().st_size)!=read(b,right['base']+position,count,Path(after).stat().st_size):
                    raise ValueError('signing changed executable bytes')
                position+=count
            for stream,row,end,path in [(a,left,ends[0],before),(b,right,ends[1],after)]:
                position=min(ends)
                while position<end:
                    count=min(CHUNK,end-position)
                    if any(read(stream,row['base']+position,count,Path(path).stat().st_size)): raise ValueError('signing removed non-padding bytes')
                    position+=count
    cds=directories(after)
    if {cd['identity'] for cd in cds if cd['slot']==0}!={row['identity'] for row in new}:
        raise ValueError('signer produced no primary CodeDirectory for a slice')
    verify_slots(after,[dict(identity=cd['identity'],slot=cd['slot'],pages=list(range(cd['count']))) for cd in cds])


def verify_artifact(path, *, require_cms=False):
    """Verify all code pages and CMS integrity; do not assert publisher trust."""
    from .component_effects import regular
    cds=directories(path)
    verify_slots(path,[dict(identity=cd['identity'],slot=cd['slot'],pages=range(cd['count'])) for cd in cds])
    size=Path(path).stat().st_size
    with regular(path) as stream:
        for layout in layouts(path):
            if layout['identity']=='dsc' or layout['signature'] is None:
                raise ValueError('Signing artifact has no Mach-O signature')
            start,span=layout['signature'];count=struct.unpack('>I',read(stream,start+8,4,size))[0]
            primary=None;cms=None
            for index in range(count):
                slot,offset=struct.unpack('>II',read(stream,start+12+index*8,8,size))
                magic,length=struct.unpack('>II',read(stream,start+offset,8,size))
                if slot==0:
                    if length>16<<20:raise ValueError('Signing CodeDirectory exceeds bound')
                    primary=read(stream,start+offset,length,size)
                if slot==0x10000:
                    if magic!=0xfade0b01 or not 8<length<=1<<20:
                        raise ValueError('Invalid signing CMS wrapper')
                    cms=read(stream,start+offset+8,length-8,size)
            if primary is None:raise ValueError('Signing artifact lacks primary CodeDirectory')
            if cms is None:
                if require_cms or not struct.unpack_from('>I',primary,12)[0]&2:
                    raise ValueError('Non-ad-hoc signing artifact lacks CMS')
                continue
            with tempfile.TemporaryDirectory(prefix='vphone-signing-cms-') as raw:
                content=Path(raw)/'CodeDirectory';content.write_bytes(primary)
                result=subprocess.run(['/usr/bin/openssl','cms','-verify','-binary','-inform','DER',
                    '-content',str(content),'-noverify','-out','/dev/null'],input=cms,capture_output=True,timeout=20)
                if result.returncode:raise ValueError('Signing artifact CMS integrity verification failed')


def reserve_signature_command(path):
    """Reserve LC_CODE_SIGNATURE before signing an injected thin image.

    Match VPhoneMachOImage.signed: drop only LC_SOURCE_VERSION when needed.
    This is a recorded loader edit, never an exception in verify_signing.
    """
    layout = layouts(path)
    if len(layout) != 1 or layout[0]['identity'] != 'thin':
        raise ValueError('signature space reservation requires a thin Mach-O')
    if layout[0]['signature'] is not None:
        return False
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, 'r+b') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('signature space input must be a private regular file')
        header = stream.read(32)
        count, size = struct.unpack_from('<II', header, 16)
        if 32 + size != layout[0]['end']:
            raise ValueError('signature space input changed')
        area = stream.read(size)
        commands, content, position = [], [], 0
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', area, position)
            raw = area[position:position + length]
            if len(raw) != length or length < 8:
                raise ValueError('invalid signature space load command')
            if cmd == 0x19:
                if length < 72:
                    raise ValueError('invalid segment command')
                sections = struct.unpack_from('<I', raw, 64)[0]
                if length != 72 + sections * 80:
                    raise ValueError('invalid section command bounds')
                for index in range(sections):
                    section = 72 + index * 80
                    offset = struct.unpack_from('<I', raw, section + 48)[0]
                    if offset:
                        content.append(offset)
                if not sections:
                    offset, span = struct.unpack_from('<QQ', raw, 40)
                    if offset and span:
                        content.append(offset)
            commands.append((cmd, raw))
            position += length
        if position != size:
            raise ValueError('signature space command size differs')
        # No section boundary means no additional edit is authorized. The
        # unchanged signer verifier still rejects overwritten nonzero bytes.
        if not content:
            return False
        first = min(content)
        if not 32 + size <= first <= info.st_size:
            raise ValueError('load commands overlap file content')
        if 32 + size + 16 <= first:
            if any(stream.read(16)):
                raise ValueError('signature space contains non-padding bytes')
            return False
        versions = [raw for cmd, raw in commands if cmd == 0x2a]
        if len(versions) != 1 or len(versions[0]) != 16:
            raise ValueError('no signature command space without LC_SOURCE_VERSION')
        kept = b''.join(raw for cmd, raw in commands if cmd != 0x2a)
        if 32 + len(kept) + 16 > first:
            raise ValueError('insufficient signature command space')
        stream.seek(16)
        stream.write(struct.pack('<II', count - 1, len(kept)))
        stream.seek(32)
        stream.write(kept + bytes(size - len(kept)))
        stream.flush()
        os.fsync(stream.fileno())
    return True
