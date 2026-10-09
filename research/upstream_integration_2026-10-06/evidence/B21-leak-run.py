from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
try:
 samples=[]
 for batch in range(4):
  for i in range(10):rpc('services.status',{'label':'com.apple.SpringBoard'})
  time.sleep(.2)
  count=shell('test "$(ps -p 2861 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && /var/root/vphone-b21-api/fd-probe 2861')
  samples.append(int(count))
 result['launchd_call_count']=40;result['fd_samples_after_each_10']=samples;result['baseline_fd_count']=13
 result['no_cumulative_fd_growth']=all(n<=13 for n in samples)
 assert result['no_cumulative_fd_growth']
 result['health_after']=health();result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-leak-run.json').write_text(text)
print(result['fd_samples_after_each_10'])
