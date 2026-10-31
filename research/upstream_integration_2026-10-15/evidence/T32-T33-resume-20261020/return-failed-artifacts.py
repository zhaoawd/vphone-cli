"""Complete the existing host driver's invoker handback for this failed run only."""
import fcntl,hashlib,json,os,stat,subprocess
from pathlib import Path
vm=Path('/Users/kolar/github/vphone-cli/vm-t32-t33-dsc-20261018')
archive=vm/'.cfw-history/20261020T000756Z-iTDO2qSV'
fd=os.open(vm,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 assert vm.stat().st_uid==501
 assert not any(vm.glob('.cfw_disk.*')) and not any(vm.glob('.cfw_mount.*'))
 record=json.loads((archive/'transaction.json').read_bytes())
 assert record['status']=='failed' and record['exit_code']==141 and record['original_check']['unchanged'] is True
 raw=(vm/'Disk.img').lstat();old=record['original']
 assert (raw.st_dev,raw.st_ino,raw.st_size,raw.st_mtime_ns)==tuple(old[k] for k in ('dev','ino','size','mtime_ns'))
 before=hashlib.sha256((archive/'transaction.json').read_bytes()).hexdigest()
 # Exact ownership policy used by cfw_install_host.sh: no symlink following,
 # no other device, no other accounts' directories and no regular hardlinks.
 for target in [archive,vm/'.cfw_temp']:
  info=target.lstat();assert stat.S_ISDIR(info.st_mode)
  subprocess.run(['/usr/bin/find','-x',str(target),'(','-type','d','!','-user','0','!','-user','501','-prune',')','-o','(','(','-type','d','-o','(','-type','f','-links','1',')',')','(','-user','0','-o','-user','501',')','-exec','/usr/sbin/chown','-h','501:20','{}','+',')'],check=True)
 assert hashlib.sha256((archive/'transaction.json').read_bytes()).hexdigest()==before
 print(json.dumps({'state':'passed','targets':[str(archive),str(vm/'.cfw_temp')],'owner':'501:20','modeUnchanged':True,'transactionSHA256':before,'diskUnchangedMetadata':True}))
finally:os.close(fd)
