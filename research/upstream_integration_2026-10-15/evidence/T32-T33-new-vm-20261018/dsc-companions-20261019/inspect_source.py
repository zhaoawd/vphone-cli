from pathlib import Path
import sys,json,hashlib,stat,subprocess,plistlib
r=Path.cwd();sys.path.insert(0,str(r/'scripts'))
from patchers.cfw_dsc_chunks import _parse_chunk_mappings
from patchers.volume_state import volume_read_only
vm=r/'vm-t32-t33-dsc-20261018';image=vm/'.cfw_temp/CryptexSystemOS.dmg';stamp=json.loads((image.parent/('.'+image.name+'.source.json')).read_text());out=r/'.build/t32-dyldreadonly-debug';mount=out/'readonly';mount.mkdir()
def sha(path):
 with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
before=sha(image);assert before==stamp['cacheSHA256'];attached=False
try:
 raw=subprocess.check_output(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-owners','on','-mountpoint',str(mount),'-plist',str(image)]);attached=True;(out/'attachment.plist').write_bytes(raw)
 raw=subprocess.check_output(['/usr/sbin/diskutil','info','-plist',str(mount)]);(out/'volume.plist').write_bytes(raw);volume=plistlib.loads(raw);assert volume_read_only(volume) and volume['MountPoint']==str(mount)
 directory=mount/'System/Library/Caches/com.apple.dyld';members=[];inventory=[]
 for path in sorted(directory.iterdir()):
  info=path.lstat();inventory.append(dict(name=path.name,size=info.st_size,mode=info.st_mode,nlink=info.st_nlink))
  if not __import__('re').fullmatch(r'dyld_shared_cache_arm64e(?:\.[0-9]{1,2}|\.symbols|\.map)?',path.name):
   info=path.lstat();assert stat.S_ISREG(info.st_mode) and not path.is_symlink()
   with path.open('rb') as stream: magic=stream.read(16).hex()
   maps=_parse_chunk_mappings(path)
   members.append(dict(name=path.name,size=info.st_size,nlink=info.st_nlink,sha256=sha(path),magic=magic,mappings=maps,executable=any(x['max_prot']&4 or x['init_prot']&4 for x in maps)))
 assert members
 result=dict(schemaVersion=1,readOnly=True,cacheSHA256=before,generationID=stamp['generationID'],sourceSHA256=stamp['sourceSHA256'],members=members,inventory=inventory)
finally:
 if attached:subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True)
assert sha(image)==before
result['cacheUnchanged']=True;(out/'source-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
