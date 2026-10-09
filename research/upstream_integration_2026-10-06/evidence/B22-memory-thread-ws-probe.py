from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
result={'health':health(),'observations':rows}
try:
 for _ in range(2):rpc('screen.screenshot')
 def sample():
  p=rpc('processes.list',{'filter':'vphoned'})['processes'];worker=next(x for x in p if 'vphone-b21-api' in x.get('path','') or x.get('name')=='vphoned' and x['pid']!=70)
  return {k:worker[k] for k in ['pid','resident_bytes','footprint_bytes']}
 result['baseline']=sample();result['batches']=[]
 for batch in range(4):
  for _ in range(5):rpc('screen.screenshot')
  result['batches'].append(sample())
 result['settled']=[]
 for _ in range(3):
  time.sleep(5);result['settled'].append(sample())
 result['retained_growth_bytes']=result['settled'][-1]['footprint_bytes']-result['baseline']['footprint_bytes']
 result['complete']=result['retained_growth_bytes']<60*1024*1024
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-memory-thread-ws-probe.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
assert result['complete'],'retained screenshot memory growth'
