import struct, hashlib
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
from pyimg4 import IM4P
p='ipsws/patch_refactor_input/kernelcache.research.vphone600'
r=open(p,'rb').read(); im=IM4P(r); im.payload.decompress(); b=im.payload.data; raw=open('ipsws/patch_refactor_input/raw_payloads/kernelcache.bin','rb').read()
print('outerSHA256',hashlib.sha256(r).hexdigest(),'payloadSHA256',hashlib.sha256(b).hexdigest(),'matchesRaw',b==raw)
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM);md.detail=True
start,end=0xab0000,0x25c0000
anchor=b.index(b'pmap_set_shared_region\0'); refs=[]
for o in range(start,end,4):
 w=struct.unpack_from('<I',b,o)[0]
 if w & 0x9f000000 != 0x90000000: continue
 n=((w>>5)&0x7ffff)<<2|((w>>29)&3); n=(n^(1<<20))-(1<<20); page=(o&~4095)+(n<<12)
 if page!=anchor&~4095:continue
 ins=list(md.disasm(b[o:o+36],o))
 for a in ins[1:]:
  if a.mnemonic=='add' and len(a.operands)==3 and a.operands[1].reg==ins[0].operands[0].reg and a.operands[2].imm==anchor&4095:refs.append(o);break
print('pmap refs',list(map(hex,refs)))
funcs=[]
for ref in refs:
 for o in range(ref,ref-0x1000,-4):
  ins=next(md.disasm(b[o:o+4],o),None)
  if ins and ins.mnemonic=='pacibsp': funcs.append(o); break
print('functions',list(map(hex,set(funcs))))
for f in set(funcs):
 callers=[]
 for o in range(start,end,4):
  w=struct.unpack_from('<I',b,o)[0]
  if w>>26 != 0b100101:continue
  n=w&0x3ffffff;n=(n^(1<<25))-(1<<25)
  if o+n*4==f:callers.append(o)
 print('callers',hex(f),list(map(hex,callers)))
 for c in callers:
  for ins in md.disasm(b[c-120:c+64],c-120):print(hex(ins.address),ins.mnemonic,ins.op_str)
