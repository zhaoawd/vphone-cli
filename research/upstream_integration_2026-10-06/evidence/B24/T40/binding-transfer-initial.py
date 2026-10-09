"""Small, explicitly synthetic VM-state transfer probe; never starts a VM.

--binding/--receipt optionally supplies exact input bytes to retain. The receipt
is an evidence copy in a VM directory; the production root store remains the
trust boundary. Copying it into a VM does not make it an authenticated receipt.
"""
import argparse,hashlib,json,os,stat,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--cli',required=True,type=Path)
p.add_argument('--output',required=True,type=Path)
p.add_argument('--binding',type=Path)
p.add_argument('--receipt',type=Path)
p.add_argument('--backend',default='system-tar',choices=['system-tar','native'])
a=p.parse_args(); a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
lib=a.output/'library';lib.mkdir(mode=0o700)
rom=a.output/'synthetic-ROM.bin';rom.write_bytes(b'SYNTHETIC ROM - not bootable\n')
report={'scope':'actual CLI transfer of synthetic small VM bundle; no VM launch or firmware/runtime acceptance',
        'cli':str(a.cli.resolve()),'cli_sha256':hashlib.sha256(a.cli.read_bytes()).hexdigest(),'commands':[]}
def run(args):
 start=time.monotonic();r=subprocess.run([str(a.cli),*args],capture_output=True,text=True,timeout=120)
 report['commands'].append({'argv':args,'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'seconds':time.monotonic()-start})
 (a.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
 assert r.returncode==0,r.stderr
run(['vm','new','--library-root',str(lib),'source','--disk-size','0','--rom',str(rom),'--seprom',str(rom)])
source=lib/'source'
if a.binding:
 binding=a.binding.read_bytes();report['binding_input']={'path':str(a.binding),'sha256':hashlib.sha256(binding).hexdigest(),'kind':'external exact bytes; authenticity not established by transfer'}
else:
 binding=b'{"bundle":"2.6.1-local.1208708c55574677","guestEnvironment":"2.6.0","kernel":"2.6.1","bootChain":"2.6.0-ci.abcdef0"}\n'
 report['binding_input']={'kind':'constructed four-origin fixture; not runtime evidence'}
(source/'launchpad.json').write_bytes(binding);os.chmod(source/'launchpad.json',0o600)
if a.receipt:
 receipt=a.receipt.read_bytes();(source/'acceptance-host-receipt-copy.json').write_bytes(receipt)
 os.chmod(source/'acceptance-host-receipt-copy.json',0o600)
 report['receipt_input']={'path':str(a.receipt),'sha256':hashlib.sha256(receipt).hexdigest(),'kind':'evidence copy; root-owned store not transferred or authenticated'}
(source/'state.bin').write_bytes(b'SYNTHETIC persistent state\n');os.chmod(source/'state.bin',0o640)
def inventory(root):
 result={}
 for path in sorted(root.rglob('*')):
  rel=str(path.relative_to(root));st=path.lstat()
  if stat.S_ISREG(st.st_mode):result[rel]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':st.st_size,'mode':stat.S_IMODE(st.st_mode)}
  elif stat.S_ISLNK(st.st_mode):result[rel]={'link':os.readlink(path)}
 return result
before=inventory(source)
run(['vm','clone','--library-root',str(lib),'source','clone'])
assert inventory(lib/'clone')==before
run(['vm','rename','--library-root',str(lib),'clone','renamed'])
assert not (lib/'clone').exists() and inventory(lib/'renamed')==before
archive=a.output/'transfer.txz'
run(['vm','export','--library-root',str(lib),'renamed','--out',str(archive),'--max','--archive-backend',a.backend])
run(['vm','import','--library-root',str(lib),str(archive),'--name','imported','--archive-backend',a.backend])
assert inventory(lib/'imported')==before
assert inventory(source)==before
report.update(complete=True,identical_file_inventory=before,archive_bytes=archive.stat().st_size,
              recorded_four_origins=json.loads(binding),
              limitations=['Synthetic ROM and 0 GiB disk; no real VM archive or restore tested',
                           'Recorded origins retained byte-for-byte; actual host/guest/kernel/boot chain identity not established',
                           'Receipt copy retained as opaque evidence; root store verification is a separate operation'])
(a.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'complete':True,'files':len(before),'archive_bytes':archive.stat().st_size,'result':str(a.output/'result.json')}))
