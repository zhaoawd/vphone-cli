import hashlib,json,socket,time
from pathlib import Path
root=Path('/private/tmp/vphone-b27');vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');runtime=json.loads((vm/'.vphone-runtime.json').read_text());assert runtime['pid']==84568
rows=[]
for lines in (256,4096,12000):
 cmd="i=0; while [ \"$i\" -lt %d ]; do printf 'B27%%05d-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n' \"$i\"; i=$((i+1)); done"%lines
 expected=b''.join(('B27%05d-'%i+'0123456789abcdef'*4+'\n').encode() for i in range(lines))
 q={'t':'shell','cmd':cmd,'timeout_ms':15000,'screen':False,'target':{'vm':vm.name,'pid':runtime['pid'],'instance_id':runtime['instanceID']}}
 start=time.monotonic()
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(35);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   b=s.recv(65536)
   if not b:raise RuntimeError('closed')
   data+=b;assert len(data)<4*1024*1024
 elapsed=time.monotonic()-start;r=json.loads(data.split(b'\n')[0]);raw=r.pop('stdout','').encode();name='throughput-%d'%lines;(root/(name+'.stdout')).write_bytes(raw)
 row={'lines':lines,'expected_bytes':len(expected),'actual_bytes':len(raw),'expected_sha256':hashlib.sha256(expected).hexdigest(),'sha256':hashlib.sha256(raw).hexdigest(),'complete':raw==expected,'seconds':elapsed,'bytes_per_second':len(raw)/elapsed,'response':r,'request':q};rows.append(row);print(json.dumps({k:v for k,v in row.items() if k!='request'}),flush=True)
(root/'classic-throughput.json').write_text(json.dumps({'scope':'Real guest classic shell response to headless host; excludes UI, helper log, console, rotation, panic and cancellation acceptance','rows':rows},indent=2)+'\n')
assert all(r['complete'] and r['response'].get('code')==0 and not r['response'].get('truncated') and not r['response'].get('timed_out') for r in rows)
