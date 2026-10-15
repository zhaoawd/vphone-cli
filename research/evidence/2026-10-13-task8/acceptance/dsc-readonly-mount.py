import pathlib,subprocess,plistlib,json
base=pathlib.Path('/private/tmp/vphone-task8-dsc-readonly');base.mkdir(exist_ok=True)
image='/private/tmp/vphone-task8-acceptance-vms/task8-before-binding/Disk.img'
def run(*args):return subprocess.check_output(args)
a=plistlib.loads(run('/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',image))
devs={e['dev-entry'].split('/')[-1] for e in a['system-entities'] if 'dev-entry' in e}
top=next(e['dev-entry'] for e in a['system-entities'] if e.get('content-hint')=='GUID_partition_scheme')
try:
 ap=plistlib.loads(run('/usr/sbin/diskutil','apfs','list','-plist'))
 volume=next(v for c in ap['Containers'] for v in c['Volumes'] if v['DeviceIdentifier'] in devs and 'System' in v.get('Roles',[]))
 root=base/'system';root.mkdir(exist_ok=True)
 run('/sbin/mount_apfs','-o','rdonly','/dev/'+volume['DeviceIdentifier'],str(root))
 info=plistlib.loads(run('/usr/sbin/diskutil','info','-plist',str(root)))
 assert (info.get('WritableVolume') is False and info.get('WritableMedia') is False)
 (base/'attachment.json').write_text(json.dumps({'top':top,'system':str(root),'readonly':(info.get('WritableVolume') is False and info.get('WritableMedia') is False)},indent=2))
 print((base/'attachment.json').read_text())
except:
 run('/usr/bin/hdiutil','detach',top);raise
