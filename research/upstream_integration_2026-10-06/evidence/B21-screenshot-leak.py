from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
try:
 samples=[]
 for _ in range(2):rpc('screen.screenshot')
 def sample():
  p=rpc('processes.list',{'filter':'vphoned'})['processes'];worker=next(x for x in p if x['pid']==4156)
  count=int(shell('test "$(ps -p 4156 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && /var/root/vphone-b21-api/fd-probe 4156'))
  return {'resident_bytes':worker['resident_bytes'],'footprint_bytes':worker['footprint_bytes'],'fd_count':count}
 baseline=sample()
 for batch in range(4):
  for _ in range(5):rpc('screen.screenshot')
  time.sleep(.2);samples.append(sample())
 result.update(warmup=2,screenshots=20,baseline=baseline,samples=samples)
 tail=[x['resident_bytes'] for x in samples[1:]];result['last_three_resident_spread_bytes']=max(tail)-min(tail)
 assert result['last_three_resident_spread_bytes']<=16*1024*1024
 assert all(x['fd_count']==baseline['fd_count'] for x in samples)
 result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-screenshot-leak.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
