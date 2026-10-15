"""Observe independent metadata files during publication; never an atomic commit proof."""
from pathlib import Path
import json,sys,re,hashlib,time,datetime
E=Path(__file__).resolve().parent;VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label=sys.argv[1];started=time.monotonic();previous=None;last=0;index=0
with (E/(label+'-metadata-observations.jsonl')).open('x') as out:
    while True:
        raw={};value={}
        for key,name in [('binding','launchpad.json'),('receipt','.firmware-component-receipts.json'),('desired','.firmware-desired-plan.json')]:
            try:
                data=(VM/name).read_bytes();body=json.loads(data);raw[key]=data;value[key+'_sha256']=hashlib.sha256(data).hexdigest()
                if key=='binding':value['binding']=body
                if key=='receipt':value['receipt_transaction_id']=body.get('transactionID')
            except (OSError,ValueError) as error:value[key+'_observation_error']=repr(error)
        finished=(E/(label+'.json')).exists();changed=value!=previous
        if changed or time.monotonic()-last>=60 or finished:
            record={**value,'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'elapsed_seconds':round(time.monotonic()-started,1),'wrapper_finished':finished,'scope':'independent per-file observations during publication; not an atomic snapshot or commit proof'}
            if changed:
                for key,data in raw.items():
                    with (E/(label+'-metadata-checkpoint-'+str(index)+'-'+key+'.json')).open('xb') as f:f.write(data)
                record['checkpoint_index']=index;index+=1
            out.write(json.dumps(record)+'\n');out.flush();print(json.dumps(record),flush=True);previous,last=value,time.monotonic()
        if finished:break
        if time.monotonic()-started>=21600:raise RuntimeError('Metadata observer duration reached; publisher not interrupted')
        time.sleep(5)
