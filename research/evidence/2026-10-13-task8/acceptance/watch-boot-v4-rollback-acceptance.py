"""Read-only guest boot acceptance for the authorized V4 VM with frozen expectations."""
from pathlib import Path
import json,subprocess,time,sys,hashlib,re
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
CLI='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
BINARY='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm'
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label=sys.argv[1]
expected_path=E/(label+'-boot-expectations.json')
expected_raw=expected_path.read_bytes();expected=json.loads(expected_raw)
out=E/(label+'-boot-watch.json');observations=E/(label+'-boot-observations.jsonl')
assert not out.exists() and not observations.exists()
assert expected['binding']['bundle']=='2.6.20261016-local'
def sha(b):return hashlib.sha256(b).hexdigest()
def check_inputs():
    raw=(VM/'launchpad.json').read_bytes()
    assert json.loads(raw)==expected['binding'] and sha(raw)==expected['binding_sha256']
    assert sha((VM/'.firmware-component-receipts.json').read_bytes())==expected['receipt_sha256']
    assert not (VM/'.firmware-transaction').exists()
    assert expected_path.read_bytes()==expected_raw
check_inputs()
started=time.monotonic();target=None
result={'passed':False,'expected':expected,'expectations_sha256':sha(expected_raw),'attempts':[]}
base=[CLI,'guest','send','task8-copy','--library-root',str(VM.parent),'--timeout','15']
def send(message):
    command=base+[json.dumps(message,separators=(',',':'))]
    try:
        p=subprocess.run(command,capture_output=True,text=True,timeout=20)
        r={'command':command,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
        try:r['response']=json.loads(p.stdout)
        except json.JSONDecodeError:pass
    except subprocess.TimeoutExpired as error:r={'command':command,'client_timeout':True,'error':str(error)}
    r['elapsed_seconds']=round(time.monotonic()-started,3)
    result['attempts'].append(r);obs.write(json.dumps(r)+'\n');obs.flush()
    return r
def verify_process(current):
    pid=current.get('pid')
    assert type(pid) is int and pid>0 and current.get('vm')=='task8-copy' and current.get('instance_id')
    p=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True,timeout=5)
    command=p.stdout.strip()
    assert p.returncode==0 and command.startswith(BINARY+' ')
    assert '--config '+str(VM/'config.plist')+' ' in command
    assert '--binding-sha256 '+expected['binding_sha256']+' ' in command
    assert re.search(r'(?:^| )--no-vphoned-update(?: |$)',command)
    assert not re.search(r'(?:^| )--no-vphoned(?: |$)',command)
    result['actual_vm_command']=command
output_file=None
try:
    with observations.open('x') as obs:
        output_file=out.open('x')
        while time.monotonic()-started<360:
            cap=send({'t':'capabilities'});body=cap.get('response',{})
            if cap.get('exit_code')==0 and body.get('ok') is True:
                current=body.get('target',{})
                verify_process(current)
                if target is None:target=current
                else:assert target==current,'VM instance changed'
                result['target']=target
            ready=(cap.get('exit_code')==0 and body.get('ok') is True and target is not None and body.get('boot_mode')=='normal' and body.get('guest_connected') is True and body.get('commands',{}).get('shell') is True)
            print(json.dumps({'elapsed_seconds':round(time.monotonic()-started,1),'guest_ready':ready,'target':target}),flush=True)
            if ready:
                shell=send({'t':'shell','cmd':'/var/jb/usr/bin/uname -a; /var/jb/usr/sbin/sysctl kern.osrelease hw.machine','timeout_ms':10000,'target':target})
                r=shell.get('response',{});output=r.get('stdout')
                if shell.get('exit_code')==0 and r.get('ok') is True and type(r.get('code')) is int and r['code']==0 and r.get('timed_out') is False and r.get('truncated') is False and isinstance(output,str) and all(t in output for t in ('Darwin','kern.osrelease:','hw.machine:')):
                    check_inputs();verify_process(target);result['guest_state']=r;result['passed']=True;break
            time.sleep(15)
except BaseException as error:
    result['error']=repr(error)
    raise
finally:
    result['elapsed_seconds']=round(time.monotonic()-started,3)
    if output_file is not None:
        output_file.write(json.dumps(result,indent=2)+'\n');output_file.close()
    print(json.dumps({k:v for k,v in result.items() if k!='attempts'}),flush=True)
    if not result['passed']:raise RuntimeError('Guest boot acceptance failed')
