import subprocess,os,sys,json,time
name=sys.argv[1];cmd=sys.argv[2:]
env={k:v for k,v in os.environ.items() if not k.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_'))}
start=time.time()
with open('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task6c/'+name+'.log','w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,env=env)
with open('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task6c/'+name+'.command.json','w') as f:json.dump({'argv':cmd,'exit':r.returncode,'seconds':time.time()-start},f)
print(name,r.returncode)
