from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
commands=['command -v launchctl; ls -l /usr/bin/launchctl /bin/launchctl 2>/dev/null || true','launchctl print system/com.vphone.B22.cache-acceptance 2>&1 || true','test ! -f /var/root/vphone-b21-api/b22-cache.log || tail -n 30 /var/root/vphone-b21-api/b22-cache.log','cat /var/root/vphone-b21-api/b22-cache-acceptance.plist','ps -A -o pid=,ppid=,comm= | grep vphoned || true']
for c in commands:shell(c)
shell('VPHONE_API_ONLY=1 /var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/b22-final-resumed.log 2>&1 &')
for _ in range(25):
 try:h=health();break
 except Exception:time.sleep(.2)
Path('/private/tmp/vphone-b22-cache-job-diagnose.json').write_text(json.dumps({'observations':rows,'health':h},indent=2)+'\n');print([x['response'].get('stdout','') for x in rows])
