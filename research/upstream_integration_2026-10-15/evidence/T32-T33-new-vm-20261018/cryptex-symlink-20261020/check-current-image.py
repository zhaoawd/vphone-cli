import datetime,json,os,sys
from pathlib import Path
sys.path.insert(0,'scripts')
import cfw_disk_txn as txn
vm=Path.cwd()/'vm-t32-t33-dsc-20261018';txn.require_lock(vm)
record=json.loads((vm/'.cfw-history/20261019T124601Z-vZh3Hh4C/transaction.json').read_bytes())
info=(vm/'Disk.img').stat();current=txn.identity(info)
fd=os.open(vm/'Disk.img',os.O_RDONLY)
try:sample=txn.sample_digest(fd,info.st_size)
finally:os.close(fd)
expected=record['original']
unchanged=all(current[k]==expected[k] for k in ('dev','ino','size','mtime_ns')) and sample==expected['sample']
assert unchanged
result=dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),reference=record['id'],currentIdentity=current,sample=sample,unchanged=True,scope='dev/inode/size/mtime and66 sampled regions; no full-image hash',pendingTransactions=[str(p) for p in vm.glob('.cfw_disk.*')])
assert not result['pendingTransactions']
(Path('.build/t32-cryptex-reinstall-debug/current-image-check.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
