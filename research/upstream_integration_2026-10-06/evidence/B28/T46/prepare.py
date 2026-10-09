import hashlib,json,plistlib,re,shutil,subprocess,tempfile
from pathlib import Path
root=Path('/private/tmp/vphone-b28-t46-ui');repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');source=repo/'.build/vphone-launchpad.app';dest=root/'T46-RealVM.app';assert not dest.exists()
shutil.copytree(source,dest,symlinks=True)
cli=dest/'Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli';helper=cli.parent.parent.parent
c=root/'controlled-cli.c';c.write_text('''#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\nint main(int argc,char **argv){if(argc>2&&!strcmp(argv[1],"vm")&&!strcmp(argv[2],"list")){puts("[]");return 0;}if(argc>1&&!strcmp(argv[1],"doctor")){char *a[]={"/usr/bin/python3","-u","/private/tmp/vphone-b28-t46-ui/run.py",NULL};execv(a[0],a);return 90;}fputs("B28 controlled CLI: unsupported command\\n",stderr);return 2;}\n''')
subprocess.run(['/usr/bin/clang',str(c),'-o',str(cli)],check=True)
for path in [cli,helper]:subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(path)],check=True,capture_output=True)
manifest_path=dest/'Contents/Resources/embedded-toolchain.json';m=json.loads(manifest_path.read_text());p=subprocess.run(['/usr/bin/codesign','-dvvv',str(cli)],capture_output=True,text=True,check=True);m['vphoneCLI']['cdhash']=re.search(r'^CDHash=(\S+)',p.stderr,re.M).group(1);m['gitHash']+='-B28-controlled-real-VM-bridge';manifest_path.write_text(json.dumps(m,indent=2)+'\n')
p=dest/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['CFBundleIdentifier']='com.vphone.cli.launchpad.b28.realvm';info['CFBundleName']='T46 Real VM';p.write_bytes(plistlib.dumps(info));subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(dest)],capture_output=True,check=True);subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(dest)],capture_output=True,check=True)
with tempfile.TemporaryDirectory(dir=root) as temp:
 data=[]
 for i,app in enumerate([source,dest]):
  copy=Path(temp)/str(i);shutil.copyfile(app/'Contents/MacOS/vphone-launchpad',copy);subprocess.run(['/usr/bin/codesign','--remove-signature',str(copy)],capture_output=True,check=True);data.append(copy.read_bytes())
 assert data[0]==data[1]
 unsigned=hashlib.sha256(data[0]).hexdigest()
artifact={'source_app':str(source),'app':str(dest),'source_implementation_head':'b4e80c575950d768737234f9fcefc7fb7aff6081','controlled_bridge':True,'production_UI_main_identical_unsigned':True,'unsigned_main_sha256':unsigned,'VM_binary':'/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm','scope':'Real guest classic shell output through controlled bridge, production UI reader/writer and quit lifecycle; no helper, no trusted launch route, no console throughput or actual panic'}
(root/'artifact.json').write_text(json.dumps(artifact,indent=2)+'\n');print(json.dumps(artifact))
