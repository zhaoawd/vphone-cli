from pathlib import Path
import subprocess,plistlib,json,hashlib,os,stat
out=Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance/installed-baseline.json'); base=Path('/private/tmp/vphone-task8-installed-baseline');base.mkdir(mode=0o700,exist_ok=False); rows=[]; device=None; result={}
def run(args):
 p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE); rows.append({'command':args,'exit':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode();return p.stdout
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  while b:=f.read(8<<20):h.update(b)
 return h.hexdigest()
try:
 image='/private/tmp/vphone-task8-acceptance-vms/task8-before-binding/Disk.img'
 a=plistlib.loads(run(['/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',image]));result['attachment']=a
 disks=[e['dev-entry'] for e in a['system-entities'] if e.get('content-hint')=='GUID_partition_scheme']; assert len(disks)==1,disks;device=disks[0]
 containers=plistlib.loads(run(['/usr/sbin/diskutil','apfs','list','-plist']))['Containers']; cs=[c for c in containers if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[device.removeprefix('/dev/')+'s1']];assert len(cs)==1;ref=cs[0]['ContainerReference'];result['volumes']={}
 for name,slice in [('preboot','s5'),('system','s1')]:
  m=base/name;m.mkdir(mode=0o700);vol='/dev/'+ref+slice;run(['/sbin/mount_apfs','-o','rdonly',vol,str(m)])
  info=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',vol]));assert info.get('ReadOnlyVolume',not info.get('WritableVolume',True))
  result['volumes'][name]={'device':vol,'readonly':True,'mount':str(m)}
  if name=='preboot':
   kernels=[]
   for root,dirs,files in os.walk(m,followlinks=False):
    for f in files:
     if f.lower() in ['kernelcache','kernelcache.research.vphone600']:
      p=Path(root)/f;s=p.lstat();assert stat.S_ISREG(s.st_mode) and s.st_nlink==1;kernels.append({'path':str(p.relative_to(m)),'size':s.st_size,'sha256':digest(p)})
   result['kernels']=kernels
  else:
   d=m/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld';result['dsc_root_exists']=d.is_dir();result['dsc_files']=[{'name':p.name,'size':p.stat().st_size} for p in sorted(d.glob('dyld_shared_cache_arm64e*'))]
except Exception as e:result['error']=repr(e)
finally:
 if device:
  try:run(['/usr/bin/hdiutil','detach',device]);result['detached']=True
  except Exception as e:result['detach_error']=repr(e)
 result['commands']=rows;out.write_text(json.dumps(result,indent=2,default=str)+'\n');print(json.dumps(result,default=str))
