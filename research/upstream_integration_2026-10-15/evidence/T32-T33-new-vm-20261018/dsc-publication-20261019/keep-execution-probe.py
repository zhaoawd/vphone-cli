"""Debug-only bounded probe of the one approved VM, without booting it."""
import hashlib,json,subprocess,time
from pathlib import Path
r=Path.cwd();out=r/'.build/t32-dyldreadonly-debug';binary=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm';expected='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125';deadline=time.monotonic()+3600
state=dict(scope='approved-vm-parameter-parser-only',approvedCDHash='89b70a253cad2adea133b3e875519afaf72c5d17',maximumSeconds=3600,vmBooted=False,probes=[])
try:
 while time.monotonic()<deadline and not (out/'stop-execution-probe').exists():
  assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected
  sig=subprocess.run(['/usr/bin/codesign','-dvvv',str(binary)],capture_output=True,text=True,check=True)
  assert 'CDHash='+state['approvedCDHash'] in sig.stderr
  result=subprocess.run([str(binary),'--config',str(r/'vm-t32-t33-dsc-20261018/config.plist'),'--t32-execution-probe'],capture_output=True,text=True,timeout=15)
  row=dict(time=time.time(),exitCode=result.returncode,stderr=result.stderr,stdout=result.stdout);state['probes'].append(row)
  assert result.returncode==-9 or (result.returncode==64 and 'Unknown option' in result.stderr),row
  (out/'execution-probes.json').write_text(json.dumps(state,indent=2)+'\n')
  print(json.dumps(dict(time=row['time'],exitCode=row['exitCode'])),flush=True)
  for _ in range(20):
   if (out/'stop-execution-probe').exists():break
   time.sleep(1)
 state['state']='stopped'
except Exception as error:
 state.update(state='failed',error=f'{type(error).__name__}: {error}');raise
finally:(out/'execution-probes.json').write_text(json.dumps(state,indent=2)+'\n')
