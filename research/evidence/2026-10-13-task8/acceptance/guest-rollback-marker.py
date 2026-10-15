"""Create or read one small guest marker through the authorized V4 host-control API."""
from pathlib import Path
import json,subprocess,sys,hashlib,base64,uuid,shlex,re
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
CLI='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
assert len(sys.argv) in (3,4)
mode,label=sys.argv[1:3]
assert mode in ('create','read') and re.fullmatch(r'[a-z0-9-]+',label)
assert (mode=='create' and len(sys.argv)==3) or (mode=='read' and len(sys.argv)==4)
out=E/(label+'-marker-'+mode+'.json')
assert not out.exists()
boot=json.loads((E/(label+'-boot-watch.json')).read_text())
assert boot['passed'] is True
expected=boot['expected'];target=boot['target']
assert expected['binding']['bundle']=='2.6.20261016-local'
def sha(b):return hashlib.sha256(b).hexdigest()
def check_inputs():
    raw=(VM/'launchpad.json').read_bytes()
    assert sha(raw)==expected['binding_sha256'] and json.loads(raw)==expected['binding']
    assert sha((VM/'.firmware-component-receipts.json').read_bytes())==expected['receipt_sha256']
    assert not (VM/'.firmware-transaction').exists()
check_inputs()
record={'passed':False,'mode':mode,'label':label,'target':target,'expected':expected,'requests':[]}
output_file=out.open('x')
base=[CLI,'guest','send','task8-copy','--library-root',str(VM.parent),'--timeout','15']
def send(message):
    command=base+[json.dumps(message,separators=(',',':'))]
    p=subprocess.run(command,capture_output=True,text=True,timeout=20)
    r={'command':command,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    record['requests'].append(r)
    response=json.loads(p.stdout);r['response']=response
    assert p.returncode==0 and response.get('ok') is True
    return response
try:
    cap=send({'t':'capabilities','target':target})
    assert cap.get('target')==target and cap.get('boot_mode')=='normal' and cap.get('guest_connected') is True and cap.get('commands',{}).get('shell') is True and cap.get('commands',{}).get('file_get') is True
    if mode=='create':
        token=str(uuid.uuid4())
        path='/private/var/tmp/task8-kernel-rollback-'+token
        content=(json.dumps({'purpose':'Task8 committed kernel rollback guest marker','uuid':token,'created_by_instance':target,'installed_expectations':expected},sort_keys=True,separators=(',',':'))+'\n').encode()
        assert len(content)<=16384
        intent={'path':path,'content_base64':base64.b64encode(content).decode(),'content_sha256':sha(content),'size':len(content),'target':target,'expected':expected}
        intent_path=E/(label+'-marker-intent.json');assert not intent_path.exists()
        with intent_path.open('x') as intent_file:
            intent_file.write(json.dumps(intent,indent=2)+'\n')
        record['marker']=intent
        command='(set -C && printf %s '+shlex.quote(content.decode())+' > '+shlex.quote(path)+')'
        check_inputs()
        response=send({'t':'shell','cmd':command,'timeout_ms':10000,'target':target})
        assert type(response.get('code')) is int and response['code']==0 and response.get('timed_out') is False and response.get('truncated') is False
    else:
        marker_path=Path(sys.argv[3]).resolve()
        assert marker_path.parent==E.resolve() and marker_path.name.endswith('-marker-create.json')
        previous=json.loads(marker_path.read_text());assert previous['passed'] is True and previous['mode']=='create'
        intent=previous['marker'];path=intent['path'];content=base64.b64decode(intent['content_base64'],validate=True)
        assert re.fullmatch(r'/private/var/tmp/task8-kernel-rollback-[0-9a-f-]{36}',path)
        assert previous['target']['instance_id']!=target['instance_id'] and previous['target']['vm']==target['vm']
        assert sha(content)==intent['content_sha256'] and len(content)==intent['size']
        record['marker']=intent;record['created_record']=str(marker_path)
    downloaded=send({'t':'file_get','path':path,'target':target})
    assert type(downloaded.get('size')) is int and downloaded['size']==len(content)
    actual=base64.b64decode(downloaded['data'],validate=True)
    assert actual==content and sha(actual)==intent['content_sha256']
    cap=send({'t':'capabilities','target':target})
    assert cap.get('target')==target and cap.get('guest_connected') is True
    check_inputs();record['downloaded_sha256']=sha(actual);record['passed']=True
except BaseException as error:
    record['error']=repr(error)
    raise
finally:
    output_file.write(json.dumps(record,indent=2)+'\n');output_file.close()
    print(json.dumps(record))
    if not record['passed']:raise RuntimeError('Guest marker acceptance failed')
