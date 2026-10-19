import datetime,json,os,plistlib,subprocess,sys
from pathlib import Path
sys.path.insert(0,'scripts')
import cfw_disk_txn as txn
from patchers import component_effects as effects
vm=Path.cwd()/'vm-t32-t33-dsc-20261018';txn.require_lock(vm)
archive=vm/'.cfw-history/20261019T065441Z-XzJThk9M'
final=json.loads((archive/'guest-effects-final.json').read_bytes())
out=Path('.build/t32-undo-mount-debug/retained-readonly');out.mkdir(exist_ok=False)
result=dict(state='running',readOnly=True,vm=str(vm),time=datetime.datetime.now(datetime.timezone.utc).isoformat(),checked=0,differences=[],errors=[])
def save():(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
before=txn.identity((vm/'Disk.img').stat());base=None;save()
try:
 raw=subprocess.check_output(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-plist','-imagekey','diskimage-class=CRawDiskImage',str(vm/'Disk.img')],stderr=subprocess.PIPE)
 (out/'attach.plist').write_bytes(raw);attached=plistlib.loads(raw)
 entities=attached['system-entities'];base=next(e['dev-entry'] for e in entities if e.get('content-hint')=='GUID_partition_scheme')
 listing=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','apfs','list','-plist']))
 container=next(c for c in listing['Containers'] if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[base.removeprefix('/dev/')+'s1'])
 roots={}
 for volume,suffix in [('system','s1'),('hardware','s3'),('preboot','s5')]:
  device=container['ContainerReference']+suffix
  details=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/dev/'+device]))
  root=details.get('MountPoint');result.setdefault('volumes',{})[volume]=details
  if root and details.get('WritableVolume') is False:roots[volume]=Path(root)
  elif root and details.get('ReadOnlyVolume') is True:roots[volume]=Path(root)
  else:raise ValueError('missing readonly mount '+device)
 roots['dsc']=roots['system']/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
 for output in final['outputs']:
  volume,rel=output['target'].split(':',1);path=roots[volume]/rel.lstrip('/')
  try:
   actual=effects.state(path,False);result['checked']+=1
   if actual!=output['state']:result['differences'].append(dict(target=output['target'],expected=output['state'],actual=actual))
  except Exception as e:result['errors'].append(dict(target=output['target'],error=str(e)))
  save()
 result['state']='passed'
finally:
 if base:
  child=subprocess.run(['/usr/bin/hdiutil','detach',base],capture_output=True,text=True)
  result['detach']=dict(exitCode=child.returncode,stdout=child.stdout,stderr=child.stderr)
  if child.returncode:result['state']='detach-failed'
 result['imageIdentityUnchanged']=txn.identity((vm/'Disk.img').stat())==before;save()
print(json.dumps({k:v for k,v in result.items() if k!='volumes'}))
