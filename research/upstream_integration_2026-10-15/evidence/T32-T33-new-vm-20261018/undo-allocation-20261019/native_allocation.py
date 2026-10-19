"""Debug-only APFS allocation observations, no VM image or guest writes."""
import json,os,subprocess,sys,time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
r=Path.cwd();sys.path.insert(0,str(r/'scripts'))
from patchers import final_guest
out=r/'.build/t32-undo-mount-debug';image=out/'allocation.sparseimage';mount=out/'mount';mount.mkdir(exist_ok=True)
subprocess.run(['/usr/bin/hdiutil','create','-size','128m','-fs','APFS','-volname','T32UndoMount','-type','SPARSE',str(image)],check=True)
attached=False
result=dict(schemaVersion=1,scope='native isolated APFS allocation; private-path qualifier replaced; all attachment and mount probes real',vmWritten=False)
try:
 raw=subprocess.check_output(['/usr/bin/hdiutil','attach','-nomount','-nobrowse','-plist',str(image)]);attached=True;(out/'native-attachment.plist').write_bytes(raw)
 os.environ['CFW_HOST_MNT']=str(mount)
 with patch.object(final_guest.gate,'private_path',side_effect=lambda plan,p:Path(p)):
  roots,before,identities=final_guest.mount_roots(SimpleNamespace(),image,{'system'},read_only=False)
 (out/'native-before.json').write_text(json.dumps(before,indent=2)+'\n')
 target=roots['system']/'allocation-test.bin'
 with target.open('wb') as stream:stream.write(os.urandom(8*1024*1024));stream.flush();os.fsync(stream.fileno())
 time.sleep(2)
 after=final_guest.attachments(image);(out/'native-after.json').write_text(json.dumps(after,indent=2)+'\n')
 info=roots['system'].lstat();same_root=(info.st_dev,info.st_ino)==identities['system']
 final_guest.require_mount(roots['system'],before['ContainerReference']+'s1',False)
 changes=[]
 def diff(a,b,path=''):
  if isinstance(a,dict) and isinstance(b,dict):
   for key in sorted(set(a)|set(b)):diff(a.get(key),b.get(key),path+'/'+key)
  elif isinstance(a,list) and isinstance(b,list) and len(a)==len(b):
   for n,(left,right) in enumerate(zip(a,b)):diff(left,right,path+'/'+str(n))
  elif a!=b:changes.append(dict(path=path,before=a,after=b))
 diff(before,after)
 assert before!=after and same_root and changes
 result.update(state='passed',wholeContainerChanged=True,rootIdentityUnchanged=same_root,actualDevicePathAndWritableStateMatched=True,changes=changes)
finally:
 if attached:
  container=final_guest.attachments(image)
  physical=container['PhysicalStores'][0]['DeviceIdentifier'].rsplit('s',1)[0]
  subprocess.run(['/usr/bin/hdiutil','detach','/dev/'+physical],check=True)
(out/'native-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
