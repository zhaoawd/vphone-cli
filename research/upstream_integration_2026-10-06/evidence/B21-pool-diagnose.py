from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
r={}
try:r['health']=health()
except Exception as e:r['health_error']=str(e)
r['processes']=shell('ps -A -o pid=,ppid=,comm= | grep vphone-b21-api/vphoned');r['log']=shell('tail -n 80 /var/root/vphone-b21-api/pool.log');r['observations']=rows
text=json.dumps(r,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-pool-diagnose.json').write_text(text);print({k:v for k,v in r.items() if k!='observations'})
