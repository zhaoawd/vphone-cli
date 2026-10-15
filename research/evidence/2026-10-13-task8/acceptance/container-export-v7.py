from pathlib import Path
import hashlib,json,fcntl,os,plistlib,stat,subprocess,tempfile
import pyimg4
E=Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance')
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
BACKUP=VM.parent/'task8-before-binding'
OUT=E/'container-export-v7.json'
assert not OUT.exists()
locks=[]
for p in [VM,BACKUP]:
 fd=os.open(p,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);locks.append(fd)
assert not (VM/'.firmware-transaction').exists()
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  while b:=f.read(16<<20):h.update(b)
 return h.hexdigest()
def data_sha(b):return hashlib.sha256(b).hexdigest()
def raw_manifest(data):
 def read(b,pos):
  start=pos;tag=b[pos];length=b[pos+1];pos+=2
  if length&128:
   n=length&127;assert 0<n<=8;length=int.from_bytes(b[pos:pos+n],'big');pos+=n
  end=pos+length;assert end<=len(b);return tag,b[start:end],b[pos:end],end
 tag,raw,body,end=read(data,0);assert tag==0x30 and end==len(data)
 parts=[];pos=0
 while pos<len(body):
  tag,raw,value,pos=read(body,pos);parts.append((tag,raw,value))
 assert parts[0][2]==b'IMG4' and parts[2][0]==0xa0
 return parts[2][1]
commands=[]
def run(args):
 p=subprocess.run(args,capture_output=True);commands.append({'command':args,'exit_code':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode();return p.stdout
def image_attachments(image):
 return [i for i in plistlib.loads(run(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if os.path.realpath(i.get('image-path',''))==str(image)]
result={'commands':commands,'kernels':{}}
try:
 for label,directory in [('baseline',BACKUP),('installed',VM/'.firmware-history/1526d1ea-9f0c-48ae-ae06-f1d65394759b')]:
  device=None;base=Path(tempfile.mkdtemp(prefix='task8-readback-',dir='/private/tmp'))
  image=directory/('kernel-disk-candidate.img' if label=='installed' else 'Disk.img');assert not image_attachments(image)
  try:
   a=plistlib.loads(run(['/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',str(image)]))
   devices=[e['dev-entry'] for e in a['system-entities'] if e.get('content-hint')=='GUID_partition_scheme'];device=devices[0] if len(devices)==1 else None;assert device is not None
   containers=plistlib.loads(run(['/usr/sbin/diskutil','apfs','list','-plist']))['Containers']
   cs=[c for c in containers if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[device.removeprefix('/dev/')+'s1']];assert len(cs)==1
   vs=[v for v in cs[0]['Volumes'] if v['DeviceIdentifier']==cs[0]['ContainerReference']+'s5'];assert len(vs)==1
   volume='/dev/'+vs[0]['DeviceIdentifier'];mount=base/'preboot';mount.mkdir()
   run(['/sbin/mount_apfs','-o','rdonly',volume,str(mount)])
   info=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]));assert info['WritableVolume'] is False and info['MountPoint']==str(mount)
   assert info['VolumeUUID']==vs[0]['APFSVolumeUUID']
   attachments=image_attachments(image);assert len(attachments)==1
   assert device in [e['dev-entry'] for e in attachments[0]['system-entities']]
   mount_identity=(mount.lstat().st_dev,mount.lstat().st_ino)
   targets=[]
   def traversal_error(e):raise e
   for root,dirs,names in os.walk(mount,followlinks=False,onerror=traversal_error):
    assert not any(n.lower() in ['kernelcache','kernelcache.research.vphone600'] for n in dirs)
    for name in names:
     if name.lower() in ['kernelcache','kernelcache.research.vphone600']:targets.append(Path(root)/name)
   assert len(targets)==1;p=targets[0];s=p.lstat();assert stat.S_ISREG(s.st_mode) and s.st_nlink==1
   data=p.read_bytes();export=Path('/private/tmp/task8-container-baseline.img4' if label=='baseline' else '/private/tmp/task8-container-installed-v7.img4');assert not export.exists();export.write_bytes(data);img=pyimg4.IMG4(data);payload=img.im4p.payload
   if payload.compression!=pyimg4.Compression.NONE:payload.decompress()
   result['kernels'][label]={'relative_path':str(p.relative_to(mount)),'image_sha256':data_sha(data),'payload_sha256':data_sha(payload.data),'im4m_sha256':data_sha(raw_manifest(data)),'readonly':True,'volume_info':info}
   after=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]))
   assert after['WritableVolume'] is False and after['MountPoint']==str(mount) and after['VolumeUUID']==info['VolumeUUID']
   assert (mount.lstat().st_dev,mount.lstat().st_ino)==mount_identity
  except BaseException as error:
   result['readback_error']=repr(error);raise
  finally:
   if device is None:
    attached=image_attachments(image)
    if attached:
     assert len(attached)==1
     backing=[e['dev-entry'] for e in attached[0]['system-entities'] if e.get('content-hint')=='GUID_partition_scheme']
     assert len(backing)==1;device=backing[0]
   if device:run(['/usr/bin/hdiutil','detach',device])
   assert not image_attachments(image)
   for p in base.iterdir():p.rmdir()
   base.rmdir()
 result['passed']=True
finally:
 [os.close(fd) for fd in locks]
 OUT.write_text(json.dumps(result,indent=2,default=str)+'\n');print(json.dumps({'passed':result.get('passed'),'kernels':{k:{x:v[x] for x in ['image_sha256','payload_sha256','im4m_sha256']} for k,v in result['kernels'].items()}}))
