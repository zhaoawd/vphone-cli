"""Bounded parser-only execution checks for the existing frozen DSC acceptance."""
import datetime,hashlib,json,os,subprocess,time
from pathlib import Path
r=Path(__file__).resolve().parents[2];d=Path(__file__).parent
binary=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm'
expected='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125'
args=[str(binary),'--config',str(r/'vm-t32-t33-dsc-20261018/config.plist'),'--vphone-acceptance-invalid-option']
status=d/'boot-readiness-live.json';events=d/'boot-readiness-during-acceptance.jsonl'
deadline=time.monotonic()+43200
try:
 while time.monotonic()<deadline:
  state=json.loads((d/'acceptance-state.json').read_text())
  record=dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),observerPID=os.getpid(),acceptanceStage=state['state'],scope='frozen parser only; does not boot, write VM, start helpers or change host policy')
  if state['state'] in ('passed','failed'):
   record.update(state='finished',reason='acceptance terminal state');status.write_text(json.dumps(record,indent=2)+'\n');break
  assert binary.stat().st_ino==246999022 and hashlib.sha256(binary.read_bytes()).hexdigest()==expected,'frozen VM executable changed'
  result=subprocess.run(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
  record.update(state='ready' if result.returncode==64 else 'not-ready',parserExitCode=result.returncode)
  with events.open('a') as stream:stream.write(json.dumps(record)+'\n')
  status.write_text(json.dumps(record,indent=2)+'\n')
  time.sleep(30)
 else:
  record.update(state='finished',reason='bounded12h deadline');status.write_text(json.dumps(record,indent=2)+'\n')
except BaseException as error:
 record=dict(recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),observerPID=os.getpid(),state='failed',error=str(error))
 status.write_text(json.dumps(record,indent=2)+'\n');raise
