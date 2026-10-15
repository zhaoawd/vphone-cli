import pathlib,subprocess,plistlib,json
base=pathlib.Path('/private/tmp/vphone-task8-volume-association');base.mkdir(exist_ok=True)
evidence=pathlib.Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance/volume-association');evidence.mkdir(exist_ok=True)
image='/private/tmp/vphone-task8-acceptance-vms/task8-before-binding/Disk.img'
def run(*args):return subprocess.check_output(args)
a=plistlib.loads(run('/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',image));top=next(e['dev-entry'] for e in a['system-entities'] if e.get('content-hint')=='GUID_partition_scheme')
try:
 ap=plistlib.loads(run('/usr/sbin/diskutil','apfs','list','-plist'));physical=top.split('/')[-1]+'s1';container=next(c for c in ap['Containers'] if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[physical]);ref=container['ContainerReference'];roots={}
 for name,suffix in [('system','s1'),('hardware','s3'),('preboot','s5')]:
  root=base/name;root.mkdir(exist_ok=True);device=ref+suffix;run('/sbin/mount_apfs','-o','rdonly','/dev/'+device,str(root));raw=run('/usr/sbin/diskutil','info','-plist','/dev/'+device);info=plistlib.loads(raw);assert info['WritableVolume'] is False
  (evidence/(name+'.plist')).write_bytes(raw);roots[name]={'device':device,'root':str(root)}
 (evidence/'images.plist').write_bytes(run('/usr/bin/hdiutil','info','-plist'));(evidence/'containers.plist').write_bytes(run('/usr/sbin/diskutil','apfs','list','-plist'));(evidence/'attachment.json').write_text(json.dumps({'image':image,'device':top,'volumes':roots},indent=2)+'\n')
 print((evidence/'attachment.json').read_text())
finally:
 r=subprocess.run(['/usr/bin/hdiutil','detach',top],capture_output=True,text=True);(evidence/'detach.json').write_text(json.dumps({'device':top,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr},indent=2)+'\n');assert r.returncode==0
