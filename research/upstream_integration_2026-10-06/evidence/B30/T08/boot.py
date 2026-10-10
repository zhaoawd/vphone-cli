#!/usr/bin/env python3
"""B29 专用研究启动脚本：显式激活已安装的 RootHide 服务。"""
import argparse,hashlib,http.client,json,os,re,secrets,signal,socket,subprocess,threading,time,uuid
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--smoke',action='store_true',help='验证就绪后正常停机；默认保持运行直到 Ctrl-C 或磁盘余量低于 5 GiB')
args=parser.parse_args()
vm=Path('/Users/qcz3840/github/vphone-cli/vm-roothide-20261010')
source=vm.parent/'vm-new'
binary=Path('/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm')
floor=5*1024**3
def free():
    info=os.statvfs(vm);return info.f_bavail*info.f_frsize
assert free()>=floor,'磁盘余量低于 5 GiB'
assert hashlib.sha256(binary.read_bytes()).hexdigest()=='c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff'
assert hashlib.sha256((vm/'.vphoned.signed').read_bytes()).hexdigest()=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
for bundle in [source,vm]:
    check=subprocess.run(['/usr/sbin/lsof','-t',str(bundle/'Disk.img')],capture_output=True,text=True)
    assert check.returncode==1 and not check.stdout.strip() and not check.stderr.strip(),f'无法确认 VM 已停机：{bundle}'
run=Path(__file__).resolve().parent/'runs'/(time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8])
run.mkdir(parents=True);os.chmod(run,0o700)
token=secrets.token_urlsafe(32);(run/'private-token').write_text(token);os.chmod(run/'private-token',0o600);stop=threading.Event();seen_prompt=threading.Event();low_disk=threading.Event();watcher_stop=threading.Event();activation_ok=threading.Event();shutdown_lock=threading.Lock();shutdown_sent=False;port=None;p=None;reader=None;watcher=None
minimum=free();reason='requested';ready=None;started=time.monotonic()
fifo=run/'serial-input';os.mkfifo(fifo,0o600);fd=os.open(fifo,os.O_RDWR)
def interrupted(_sig,_frame):stop.set()
signal.signal(signal.SIGINT,interrupted);signal.signal(signal.SIGTERM,interrupted)
def request_shutdown():
    global shutdown_sent
    with shutdown_lock:
        if not shutdown_sent and p is not None and p.poll() is None:
            shutdown_sent=True
            try:p.send_signal(signal.SIGINT)
            except ProcessLookupError:pass
def watch_disk():
    global minimum
    while not watcher_stop.is_set():
        minimum=min(minimum,free())
        if minimum<floor:
            low_disk.set();stop.set()
            request_shutdown()
            return
        watcher_stop.wait(.5)
def drain():
    global port
    with (run/'console-redacted.log').open('wb') as output:
        for line in iter(p.stdout.readline,b''):
            if b'[location] got location:' in line:line=b'[location] got location: [coordinates omitted]\n'
            output.write(line);output.flush()
            if re.search(rb'(?m)^B29_RESEARCH_ACTIVATION_EXIT:0\r*\n',line):activation_ok.set()
            match=re.search(rb'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',line)
            if match:port=int(match[1])
            if b'root#' in line or b'[control] connected to vphoned' in line:seen_prompt.set()
def rpc(method=None,params=None):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=4)
    try:
        headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}
        if method:c.request('POST','/v1/rpc',json.dumps({'method':method,'params':params or {},'id':'B29'}),headers)
        else:c.request('GET','/v1/health',headers=headers)
        response=c.getresponse();data=json.loads(response.read());assert response.status==200,data
        return data['result'] if method else data
    finally:c.close()
try:
    command=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--headless','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update','--api-listen','127.0.0.1:0']
    p=subprocess.Popen(command,stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=dict(os.environ,VPHONE_API_TOKEN=token,NSUnbufferedIO='YES'))
    watcher=threading.Thread(target=watch_disk);watcher.start()
    (run/'process.json').write_text(json.dumps({'monitor_pid':os.getpid(),'vm_pid':p.pid,'arguments':command},indent=2)+'\n')
    print('BOOT',vm,'evidence',run,flush=True)
    reader=threading.Thread(target=drain);reader.start();activated=False
    while p.poll() is None and not stop.is_set():
        minimum=min(minimum,free())
        if minimum<floor:reason='disk_below_5_GiB';break
        if seen_prompt.is_set() and not activated:
            # 串口仍由系统 iosbinpack64 bash 提供。所有客户机改动限定于该测试 VM。
            serial='echo B29_RESEARCH_ACTIVATE; VPHONE_API_ONLY=1 /var/root/vphone-b29-api/vphoned </dev/null >/var/root/vphone-b29-api/launcher.log 2>&1 & /private/var/containers/Bundle/Application/.jbroot-000114514191980C/bin/sh /rootfs/var/root/vphone-b29-control/activate.sh >/var/root/vphone-b29-control/launcher-activation.log 2>&1; echo B29_RESEARCH_ACTIVATION_EXIT:$?\n'
            os.write(fd,serial.encode());activated=True
        if ready is None and port and activation_ok.is_set():
            try:
                health=rpc();assert health['binary_hash']=='83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07'
                device=rpc('device.info');assert device['jailbreak']['layout']=='roothide'
                bootstrap=rpc('bootstrap.inspect');assert bootstrap['roots']==['/private/var/containers/Bundle/Application/.jbroot-000114514191980C']
                service=rpc('services.status',{'label':'wiki.qaq.irisind'});assert service['loaded'] is True
                addresses=device['network']['addresses'];ip=next(x.split()[1] for x in addresses if x.startswith('en0 192.168.64.'))
                with socket.create_connection((ip,2222),timeout=3) as client:
                    client.settimeout(3);banner=client.recv(256).decode('ascii');assert banner.startswith('SSH-2.0-OpenSSH_9.2')
                ready={'health':health,'jailbreak':device['jailbreak'],'boot_session_uuid':device['boot_session_uuid'],'bootstrap':bootstrap,'irisin_service':service,'ssh_banner':banner,'authentication_attempted':False,'automatic_CFW_activation':False,'explicit_research_activation':True,'elapsed':time.monotonic()-started}
                (run/'ready.json').write_text(json.dumps(ready,indent=2)+'\n');print('READY: RootHide, Irisin loaded, OpenSSH banner; free_GiB=%.2f'%(free()/1024**3),flush=True)
                if args.smoke:reason='smoke_complete';break
            except (OSError,AssertionError,KeyError,StopIteration,ValueError,http.client.HTTPException):pass
        if ready is None and time.monotonic()-started>360:reason='readiness_timeout';break
        stop.wait(.5)
finally:
    if low_disk.is_set():reason='disk_below_5_GiB'
    if p is not None:
        if p.poll() is None:
            request_shutdown()
            try:p.wait(timeout=45)
            except subprocess.TimeoutExpired:p.kill();p.wait();reason+=';forced_kill'
        if reader:reader.join(timeout=10)
    watcher_stop.set()
    if watcher:watcher.join(timeout=2)
    os.close(fd)
    if low_disk.is_set():reason='disk_below_5_GiB'+(';forced_kill' if 'forced_kill' in reason else '')
    console=(run/'console-redacted.log').read_text(errors='replace') if (run/'console-redacted.log').exists() else ''
    released={}
    for bundle in [source,vm]:
        check=subprocess.run(['/usr/sbin/lsof','-t',str(bundle/'Disk.img')],capture_output=True,text=True)
        released[bundle.name]=check.returncode==1 and not check.stdout.strip() and not check.stderr.strip()
    normal_shutdown='ApplePSCI - system off' in console and '[vphone] Guest stopped' in console and '[vphone] second SIGINT' not in console and '[vphone] guest did not shut down' not in console
    result={'normal_guest_shutdown':normal_shutdown,'disk_handles_released':released,'activation_exit_zero':activation_ok.is_set(),'vm_exit':p.returncode if p else None,'reason':reason,'minimum_free_bytes':minimum,'final_free_bytes':free(),'ready':ready is not None,'elapsed':time.monotonic()-started}
    (run/'exit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
if low_disk.is_set():raise SystemExit(2)
assert ready is not None and p.returncode==0 and normal_shutdown and all(released.values()) and reason!='readiness_timeout',result
