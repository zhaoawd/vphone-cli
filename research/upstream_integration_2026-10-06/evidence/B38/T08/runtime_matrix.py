"""本轮固定默认 API 的可重复运行验收；finally 恢复时区、位置、旋转和测试服务。"""
import base64
import concurrent.futures
import hashlib
import json
from pathlib import Path
import plistlib
import time
import client

record={'checks':[],'memory_batches':[],'restoration':{}}
label='com.vphone.B38.fd-probe';temp='/var/root/vphone-b38-api';job=temp+'/fd.plist'
location='/var/mobile/Library/Caches/vphone-location.json'
zone=rotation=front=location_before=None;changed_location=False;service_created=False

def call(method, params={}, status=200, save=True):
    r=client.rpc(method,params)
    if method=='screen.screenshot' and r['http_status']==200:
        data=base64.b64decode(r['reply']['result']['data'])
        summary={k:v for k,v in r['reply']['result'].items() if k!='data'}
        summary['jpeg_sha256']=hashlib.sha256(data).hexdigest();summary['jpeg_bytes']=len(data)
        r=dict(r,reply={'result':summary});call.last_jpeg=data
    if save: record['checks'].append(r)
    assert r['http_status']==status,r
    return r.get('reply',{}).get('result',r['reply'])

def read(path): return call('files.read',{'path':path,'binary':True})
def write(path,data): return call('files.write',{'path':path,'encoding':'base64','content':base64.b64encode(data).decode()},save=False)
def sample():
    rows=call('processes.list',{'filter':'vphoned-api'},save=False)['processes']
    value=next(x for x in rows if x['pid']==worker)
    return {k:value[k] for k in ('pid','ppid','footprint_bytes','resident_bytes','start_time')}
def fd_sample():
    removal=client.rpc('files.remove',{'path':temp+'/fd.json'})
    assert removal['http_status'] in (200,400),removal
    call('services.start',{'label':label})
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        reply=client.rpc('files.read',{'path':temp+'/fd.json','binary':True})
        if reply['http_status']==200:
            data=base64.b64decode(reply['reply']['result']['content']).splitlines()
            if data:
                value=json.loads(data[-1]);assert value['pid']==worker
                return value
        time.sleep(.1)
    record['fd_failure_status']=client.rpc('services.status',{'label':label});record['fd_failure_stderr']=client.rpc('files.read',{'path':temp+'/fd.err'});raise AssertionError('fd probe output not produced')

try:
    health=client.rpc()['reply']; expected=json.loads((client.evidence/'default-artifact.json').read_text())
    assert health['binary_hash']==expected['api_sha256']
    record['health_before']=health
    worker=call('device.info')['agent']['pid'];record['worker_pid']=worker
    call('screen.unlock',{'timeout':10})
    rotation=call('display.rotation');front=call('apps.foreground');zone=call('time.timezone')
    before=client.rpc('files.read',{'path':location,'binary':True})
    if before['http_status']==200: location_before=base64.b64decode(before['reply']['result']['content'])
    else: assert before['http_status']==400,before
    call('files.mkdir',{'path':temp})
    image=client.code/'.build/research-b38/fd-probe'
    write(temp+'/fd-probe',image.read_bytes());call('files.chmod',{'path':temp+'/fd-probe','mode':'755'})
    write(job,plistlib.dumps({'Label':label,'UserName':'root','ProgramArguments':[temp+'/fd-probe',str(worker)],'RunAtLoad':False,'KeepAlive':False,'StandardOutPath':temp+'/fd.json','StandardErrorPath':temp+'/fd.err'}))
    call('services.load',{'paths':[job]});service_created=True
    fd_sample.started=time.time();record['fd_before']=fd_sample()
    assert call('services.status',{'label':label})['loaded']
    call('services.stop',{'label':label,'force':True})
    call('camera.status',{},400)
    for z in ['America/New_York','Asia/Tokyo']:
        result=call('time.timezone',{'identifier':z});assert result['identifier']==z and result['automatic'] is False
        assert call('time.timezone',{'identifier':z})['changed'] is False
    for z in ['../etc/passwd','Mars/Olympus']:call('time.timezone',{'identifier':z},400)
    assert call('time.timezone',{'automatic':True})['automatic'] is True
    changed_location=True
    call('location.set',{'latitude':31.2345,'longitude':121.5678})
    current=call('location.current');assert current['simulated'] is True and current['latitude']==31.2345
    call('location.set',{'latitude':91,'longitude':0},400)
    call('location.set',{'latitude':float('nan'),'longitude':0},400)
    call('location.set',{'latitude':float('inf'),'longitude':0},400)
    non_utf=b'\xff\xfe\x00\x80abc'
    write(temp+'/nonutf8',non_utf)
    result=call('files.read',{'path':temp+'/nonutf8'});assert result['encoding']=='base64' and base64.b64decode(result['content'])==non_utf
    call('files.write',{'path':temp+'/multilingual','content':'中文 Ελληνικά 日本語\n'})
    assert call('files.read',{'path':temp+'/multilingual'})['content']=='中文 Ελληνικά 日本語\n'
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        outcomes=list(pool.map(lambda _:client.rpc('services.status',{'label':'com.apple.SpringBoard'}),range(40)))
    assert all(r['http_status']==200 for r in outcomes);record['concurrent_service_queries']=outcomes
    call('display.rotation_lock',{'locked':False})
    call('apps.launch',{'bundle_id':'com.apple.mobilesafari'});time.sleep(.7)
    record['rotation_matrix']=[]
    for degrees in [90,270,0,180]:
        r=client.rpc('display.rotation',{'orientation':str(degrees)})
        record['checks'].append(r);time.sleep(.5)
        actual=call('display.rotation');shot=call('screen.screenshot')
        path=client.evidence/('safari-'+str(degrees)+'.jpeg');path.write_bytes(call.last_jpeg)
        record['rotation_matrix'].append({'requested':degrees,'change':r,'actual':actual,'screenshot':shot,'image':path.name})
        if degrees in (90,270,0): assert r['http_status']==200 and actual['degrees']==degrees
        else: assert r['http_status']==400 and actual['degrees']==0
    for _ in range(4):call('screen.screenshot')
    time.sleep(5);record['memory_baseline']=sample()
    for batch in range(3):
        for _ in range(20):call('screen.screenshot')
        burst=sample();time.sleep(5);settled=sample()
        record['memory_batches'].append({'batch':batch,'screenshots':20,'burst':burst,'settled':settled})
        print('memory',batch,settled['footprint_bytes'],flush=True)
    record['memory_final_samples']=[]
    for _ in range(3):
        time.sleep(5);record['memory_final_samples'].append(sample())
    fd_sample.started=time.time();record['fd_after']=fd_sample()
    assert record['fd_after']['fds']==record['fd_before']['fds']
    growth=record['memory_final_samples'][-1]['footprint_bytes']-record['memory_baseline']['footprint_bytes']
    record['settled_growth_bytes']=growth
    assert growth<60*1024**2,record['memory_final_samples']
    assert max(x['settled']['footprint_bytes'] for x in record['memory_batches'])<record['memory_baseline']['footprint_bytes']+60*1024**2
    record['health_after']=client.rpc()['reply'];assert record['health_after']['instance_id']==health['instance_id']
    record['classic_after']=client.ctl('app_list',filter='running');assert record['classic_after']['ok']
    record['complete']=True
except BaseException as e:
    record['failure']={'type':type(e).__name__,'message':str(e)}
    raise
finally:
    def restore(name,action):
        try:record['restoration'][name]=action()
        except BaseException as e:record['restoration'][name]={'failure':str(e)}
    if zone:
        restore('timezone_identifier',lambda:call('time.timezone',{'identifier':zone['identifier']}))
        restore('timezone_automatic',lambda:call('time.timezone',{'automatic':zone['automatic']}))
        restore('timezone_readback',lambda:call('time.timezone'))
    if changed_location:
        if location_before is None:restore('location',lambda:call('location.clear'))
        else:restore('location',lambda:write(location,location_before))
    if rotation:
        restore('orientation',lambda:call('display.rotation',{'orientation':str(rotation['degrees'])}))
        restore('rotation_lock',lambda:call('display.rotation_lock',{'locked':rotation['locked']}))
    if front:restore('frontmost',lambda:call('apps.launch',{'bundle_id':front['bundle_id']}))
    if service_created:restore('fd_probe_unload',lambda:call('services.unload',{'paths':[job],'force':True}))
    restore('test_files',lambda:call('files.remove',{'path':temp,'recursive':True}))
    client.save('runtime-matrix.json',record)
print(json.dumps({'complete':record.get('complete'), 'memory_growth':record.get('settled_growth_bytes'),'fd_before':record.get('fd_before'),'fd_after':record.get('fd_after')}))
