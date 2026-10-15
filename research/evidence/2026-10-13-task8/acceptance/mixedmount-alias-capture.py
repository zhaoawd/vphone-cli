import pathlib,subprocess,plistlib,json
base=pathlib.Path('/tmp/vphone-task8-mixedmount');base.mkdir(exist_ok=True)
evidence=pathlib.Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance/mixedmount-alias');evidence.mkdir(exist_ok=True)
image='/private/tmp/vphone-task8-mixedmount-candidate.img'
def run(*args):return subprocess.check_output(args)
a=plistlib.loads(run('/usr/bin/hdiutil','attach','-nomount','-nobrowse','-plist',image));top=next(e['dev-entry'] for e in a['system-entities'] if e.get('content-hint')=='GUID_partition_scheme')
try:
 ap=plistlib.loads(run('/usr/sbin/diskutil','apfs','list','-plist'));physical=top.split('/')[-1]+'s1';container=next(c for c in ap['Containers'] if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[physical]);ref=container['ContainerReference'];roots={}
 for name,suffix in [('hardware','s3'),('preboot','s5'),('system','s1')]:
  root=base/name;root.mkdir(exist_ok=True);device=ref+suffix;run('/sbin/mount_apfs','-o',('rw' if name=='preboot' else 'rdonly'),'/dev/'+device,str(root));raw=run('/usr/sbin/diskutil','info','-plist','/dev/'+device);info=plistlib.loads(raw)
  (evidence/(name+'.plist')).write_bytes(raw); print(name, {k:info.get(k) for k in ['MountPoint','Writable','WritableMedia','WritableVolume','ReadOnlyVolume']}, 'statvfs_flags', __import__('os').statvfs(root).f_flag);roots[name]={'device':device,'root':str(root)}
 for name,entry in roots.items():
  raw=run('/usr/sbin/diskutil','info','-plist','/dev/'+entry['device']);info=plistlib.loads(raw);(evidence/(name+'.plist')).write_bytes(raw);print('final',name,{k:info.get(k) for k in ['Writable','WritableMedia','WritableVolume','MountPoint']}, 'statvfs_flags', __import__('os').statvfs(entry['root']).f_flag)
 (evidence/'images.plist').write_bytes(run('/usr/bin/hdiutil','info','-plist'));(evidence/'containers.plist').write_bytes(run('/usr/sbin/diskutil','apfs','list','-plist'));(evidence/'attachment.json').write_text(json.dumps({'image':image,'device':top,'volumes':roots},indent=2)+'\n')
 print((evidence/'attachment.json').read_text())
finally:
 r=subprocess.run(['/usr/bin/hdiutil','detach',top],capture_output=True,text=True);(evidence/'detach.json').write_text(json.dumps({'device':top,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr},indent=2)+'\n');assert r.returncode==0
