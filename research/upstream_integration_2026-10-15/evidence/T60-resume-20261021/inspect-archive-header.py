import json,subprocess,tarfile
from pathlib import Path
root=Path.cwd()
zstd=root/'.build/t60-remaining-r3-20261021.app/Contents/Helpers/vphone-cli.app/Contents/Resources/.tools/bin/zstd'
archive=root/'.build/t60-remaining-20261021/real-vm-r3/archives/legacy.tzst'
p=subprocess.Popen([str(zstd),'-dc',str(archive)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
try:
 with tarfile.open(fileobj=p.stdout,mode='r|') as tf:
  for member in tf:
   if member.name.endswith('/Disk.img'):
    print(json.dumps(dict(name=member.name,size=member.size,type=member.type.decode(),sparse=member.sparse,pax=member.pax_headers)))
    break
finally:
 p.stdout.close()
 if p.poll() is None:p.terminate()
 p.wait()
