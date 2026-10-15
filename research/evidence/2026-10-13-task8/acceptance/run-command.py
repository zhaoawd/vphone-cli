import sys,subprocess,json,time,pathlib
name=sys.argv[1]; cmd=sys.argv[2:]; root=pathlib.Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance'); start=time.time()
with (root/(name+'.log')).open('w') as out:
 p=subprocess.run(cmd,stdout=out,stderr=subprocess.STDOUT)
r={'command':cmd,'exit_code':p.returncode,'elapsed_seconds':time.time()-start,'log':name+'.log'}
(root/(name+'.json')).write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r)); print((root/(name+'.log')).read_text()[-5000:]);sys.exit(p.returncode)
