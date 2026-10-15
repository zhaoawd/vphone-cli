"""Read-only progress observations; publication/readback determine acceptance."""
from pathlib import Path
import datetime,json,time,sys,re,os
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
assert os.geteuid()==0, 'Root is required to observe the root-created transaction directory'
label=sys.argv[1];out=E/(label+'-root-observations.jsonl');started=time.monotonic();previous=None;last=0
with out.open('x') as stream:
    while True:
        value={'phase':'before-transaction-or-archived'}
        journal=VM/'.firmware-transaction/journal.json'
        try:
            try:
                journal.stat()
            except FileNotFoundError:
                pass
            else:
                data=json.loads(journal.read_text());disk=data.get('kernelDisk') or {}
                value={'transaction_id':data['id'],'journal_version':data['version'],'phase':data['phase'],'cursor':disk.get('cursor'),'blocks':len(disk.get('offsets',[])),'pending':disk.get('pending'),'direction':disk.get('direction'),'rollback_target':(data.get('rollbackSelection') or {}).get('targetTransactionID')}
        except (OSError,ValueError,KeyError) as error:value={'observation_error':repr(error)}
        finished=(E/(label+'.json')).exists()
        if value!=previous or time.monotonic()-last>=60 or finished:
            record={**value,'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'observer_elapsed_seconds':round(time.monotonic()-started,1),'wrapper_finished':finished}
            stream.write(json.dumps(record)+'\n');stream.flush();print(json.dumps(record),flush=True);previous,last=value,time.monotonic()
        if finished:break
        if time.monotonic()-started>=21600:raise RuntimeError('Progress observer maximum duration reached; publication process not interrupted')
        time.sleep(5)
