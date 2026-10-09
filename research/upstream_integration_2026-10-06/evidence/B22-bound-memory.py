from pathlib import Path
exec(Path('/private/tmp/vphone-b22-bound-common.py').read_text())
a=json.loads(Path('/private/tmp/vphone-b22-cache-fixed-artifact.json').read_text());assert health()['binary_hash']==a['sha256']
p=shell('ps -A -o pid=,ppid=,comm= | grep vphone-b21-api/vphoned').splitlines();proxy=next(int(x.split()[0]) for x in p if x.split()[1]=='1');worker=next(int(x.split()[0]) for x in p if x.split()[1]==str(proxy))
result={'artifact_sha256':a['sha256'],'worker':worker,'observations':rows,'batches':[]}
try:
 for _ in range(2):rpc_http('screen.screenshot')
 def sample():
  ps=rpc_http('processes.list',{'filter':'vphoned'})['processes'];x=next(x for x in ps if x['pid']==worker)
  return {k:x[k] for k in ['pid','resident_bytes','footprint_bytes']}
 result['baseline']=sample();result['fd_baseline']=shell('/var/root/vphone-b21-api/fd-probe '+str(worker))
 for batch in range(8):
  for _ in range(5):rpc_http('screen.screenshot')
  result['batches'].append(sample());print(result['batches'][-1],flush=True)
 result['settled']=[]
 for _ in range(3):time.sleep(5);result['settled'].append(sample())
 result['fd_after']=shell('/var/root/vphone-b21-api/fd-probe '+str(worker))
 result['growth_bytes']=result['settled'][-1]['footprint_bytes']-result['baseline']['footprint_bytes'];result['complete']=result['growth_bytes']<60*1024*1024
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-bound-memory.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
assert result['complete']
