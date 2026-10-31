from pathlib import Path
import hashlib,json,subprocess,sys
root=Path.cwd(); work=root/'.build/t60-remaining-20261021/sealed-sparse-probe';work.mkdir()
cli=root/'.build/t60-remaining-r3-20261021.app/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli'
def run(*args):subprocess.run([str(cli),*map(str,args)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
run('vm','new','probe','--library-root',work/'source','--disk-size','1')
a=work/'source/probe/Disk.img'
with a.open('r+b') as f:f.seek(512<<20);f.write(b'A'*4096)
run('vm','export','probe','--library-root',work/'source','--out',work/'probe.tzst','--archive-backend','native')
run('vm','import',work/'probe.tzst','--library-root',work/'imported','--archive-backend','native')
b=work/'imported/probe/Disk.img'
def digest(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
result=dict(sourceAllocated=a.stat().st_blocks*512,targetAllocated=b.stat().st_blocks*512,logical=a.stat().st_size,contentMatch=digest(a)==digest(b))
print(json.dumps(result),flush=True)
assert result['contentMatch']
assert result['sourceAllocated'] < result['logical']//2
assert result['targetAllocated'] < result['logical']//2
