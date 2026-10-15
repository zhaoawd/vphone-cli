from pathlib import Path
import hashlib,json,fcntl,os,plistlib,stat,subprocess,tempfile
import pyimg4
E=Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance')
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
BACKUP=VM.parent/'task8-before-binding'
OUT=E/'committed-readback-v8.json'
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
def raw_manifest(data, index=2):
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
 return parts[index][1]
commands=[]
def run(args):
 p=subprocess.run(args,capture_output=True);commands.append({'command':args,'exit_code':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode();return p.stdout
def image_attachments(image):
 return [i for i in plistlib.loads(run(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if os.path.realpath(i.get('image-path',''))==str(image)]
result={'commands':commands}
try:
 binding=json.loads((VM/'launchpad.json').read_text());publication=json.loads((VM/'.firmware-component-receipts.json').read_text());tx=publication['transactionID'];archive=VM/'.firmware-history'/tx
 journal=json.loads((archive/'journal.json').read_text());proof=json.loads((archive/'installed-component-proof.json').read_text());receipt=publication['installed'];kd=journal['kernelDisk']
 for name in ['journal.json','installed-component-proof.json','component-receipts.json','report.json']:
  (E/('committed-v8-'+name)).write_bytes((archive/name).read_bytes())
 (E/'binding-after-update-v8.json').write_bytes((VM/'launchpad.json').read_bytes())
 result.update(binding=binding,transaction_id=tx,proof=proof,receipt=receipt)
 assert journal['id']==tx and journal['kernelOnly'] is True and journal['version']==3 and publication['records']==[]
 assert journal['phase']=='committed' and kd['cursor']==len(kd['offsets']) and not kd['pending'] and kd['direction']=='forward'
 before=json.loads((E/'binding-before-update-v8.json').read_text());assert binding=={**before,'kernel':'2.6.20261020-local'}
 assert publication['originLayer']=='kernel' and receipt['scope']=='installedComponent' and receipt['state']=='committed' and receipt['component']=='kernelcache'
 assert len(receipt['outputs'])==1 and receipt['outputs'][0]['path']=='Disk.img'
 desired=json.loads((E/'prepared-desired-plan.json').read_text());assert receipt['planSHA256']==desired['planSHA256'] and journal['plan']==desired['plan']
 assert proof['executableSHA256']==json.loads((E/'core-candidate-v8-manifest.json').read_text())['artifacts']['vphone-cli']['sha256']
 assert sha(archive/'component-receipts.json')==sha(VM/'.firmware-component-receipts.json')==journal['componentReceiptsSHA256']
 assert sha(archive/'installed-component-proof.json')==publication['originProofSHA256']
 assert sha(archive/'report.json')==journal['reportSHA256']
 report=json.loads((archive/'report.json').read_text())
 assert [effect['record'] for effect in receipt['effects']]==[record for component in report['components'] for record in component.get('records',[])]
 baseline=json.loads((E/'pre-update-v8-snapshot.json').read_text())['files']
 files={}
 for name,old in baseline.items():
  p=VM/name;digest=sha(p);files[name]={'sha256':digest,'inode':p.stat().st_ino,'inode_unchanged':p.stat().st_ino==old['inode'],'content_unchanged':digest==old['sha256']}
  assert files[name]['inode_unchanged']
  if name!='Disk.img':assert files[name]['content_unchanged']
 result['files']=files
 assert files['Disk.img']['sha256']==kd['candidateSHA256']==proof['imageSHA256']==receipt['outputs'][0]['sha256']
 assert kd['originalSHA256']==baseline['Disk.img']['sha256']
 assert proof['version']=='2.6.20261020-local' and proof['transactionID']==tx
 assert receipt['generationID']==journal['options']['generationID']
 assert receipt['desiredSHA256']==journal['options']['desiredSHA256']
 result['kernels']={}
 for label,directory in [('baseline',BACKUP),('installed',VM)]:
  device=None;base=Path(tempfile.mkdtemp(prefix='task8-readback-',dir='/private/tmp'))
  image=directory/'Disk.img';assert not image_attachments(image)
  try:
   a=plistlib.loads(run(['/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',str(directory/'Disk.img')]))
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
   data=p.read_bytes();img=pyimg4.IMG4(data);payload=img.im4p.payload
   if payload.compression!=pyimg4.Compression.NONE:payload.decompress()
   result['kernels'][label]={'relative_path':str(p.relative_to(mount)),'image_sha256':data_sha(data),'payload_sha256':data_sha(payload.data),'im4m_sha256':data_sha(raw_manifest(data)),'im4p_sha256':data_sha(raw_manifest(data,1)),'readonly':True,'volume_info':info}
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
 assert result['kernels']['baseline']['image_sha256']==json.loads((E/'installed-baseline.json').read_text())['kernels'][0]['sha256']
 assert result['kernels']['baseline']['im4m_sha256']==result['kernels']['installed']['im4m_sha256']
 assert result['kernels']['installed']['payload_sha256']==proof['payloadSHA256']
 assert result['kernels']['installed']['im4p_sha256']==proof['im4pSHA256']
 assert result['kernels']['installed']['image_sha256']==result['kernels']['baseline']['image_sha256']
 result['original_description_and_PAYP_restored']=True
 result['disk_sha256_after_readonly']=sha(VM/'Disk.img');assert result['disk_sha256_after_readonly']==files['Disk.img']['sha256']
 result['passed']=True
except Exception as e:result['error']=repr(e);raise
finally:
 try:
  result['remaining_attachments']={str(d):image_attachments(d/'Disk.img') for d in [VM,BACKUP]}
 except Exception as e:result['attachment_check_error']=repr(e)
 cleanup_failed='attachment_check_error' in result or any(result.get('remaining_attachments',{}).values())
 if cleanup_failed:result['passed']=False
 [os.close(fd) for fd in locks]
 OUT.write_text(json.dumps(result,indent=2,default=str)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['commands','receipt']},default=str))
 if cleanup_failed:raise RuntimeError('Final attachment cleanup verification failed')
