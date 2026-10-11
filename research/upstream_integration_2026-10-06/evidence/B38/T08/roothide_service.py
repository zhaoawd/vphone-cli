"""当前默认 API 在实际 RootHide 物理根内运行测试服务；不覆盖系统服务。"""
import base64
import json
import plistlib
import time
import client
rows=[]
def rpc(m,p={},status=200):
    r=client.rpc(m,p);rows.append(r);assert r['http_status']==status,r
    return r['reply'].get('result')
root=rpc('bootstrap.inspect')['jbroot']
program=root+'/tmp/vphone-b38-signal-fixture';out=root+'/tmp/vphone-b38-signal.json'
label='com.vphone.B38.roothide-service';job=root+'/Library/LaunchDaemons/'+label+'.plist'
result={'root':root,'scope':'explicit physical RootHide paths; does not assert process-wide root discovery','observations':rows}
assert rpc('services.status',{'label':label})['loaded'] is False
try:
    image=client.code/'.build/research-b38/signal-fixture'
    rpc('files.write',{'path':program,'content':base64.b64encode(image.read_bytes()).decode(),'encoding':'base64'})
    rpc('files.chmod',{'path':program,'mode':'755'})
    data=plistlib.dumps({'StandardOutPath':out,'StandardErrorPath':out,'Label':label,'UserName':'root','ProgramArguments':[program],'RunAtLoad':False,'KeepAlive':False,'ThrottleInterval':1})
    rpc('files.write',{'path':job,'content':base64.b64encode(data).decode(),'encoding':'base64'})
    rpc('services.load',{'paths':[job]})
    rpc('services.load',{'paths':[job]})
    rpc('services.start',{'label':label})
    for _ in range(20):
        r=rpc('services.status',{'label':label})
        if r['running']:break
        time.sleep(.1)
    assert r['running'] and r['pid']>0,r
    result['pid']=r['pid']
    result['fixture_signal_state']=rpc('files.read',{'path':out})
    rpc('services.signal',{'label':label,'signal':'TERM','force':True})
    for _ in range(50):
        r=rpc('services.status',{'label':label})
        if not r['running']:break
        time.sleep(.1)
    if r['running']: result['processes_after_signal']=rpc('processes.list',{'filter':'sleep'})
    assert r['running'] is False,r
    rpc('services.start',{'label':label})
    for _ in range(50):
        if rpc('services.status',{'label':label})['running']:break
        time.sleep(.1)
    assert rpc('services.status',{'label':label})['running']
    rpc('services.stop',{'label':label,'force':True})
    for _ in range(50):
        if not rpc('services.status',{'label':label})['running']:break
        time.sleep(.1)
    assert rpc('services.status',{'label':label})['running'] is False
    rpc('services.remove',{'label':label,'force':True})
    result['complete']=True
finally:
    result['unload']=client.rpc('services.unload',{'paths':[job],'force':True})
    result['final_status']=client.rpc('services.status',{'label':label})
    result['cleanup']=client.rpc('files.remove',{'path':job})
    result['program_cleanup']=client.rpc('files.remove',{'path':program});result['log_cleanup']=client.rpc('files.remove',{'path':out})
    client.save('roothide-service.json',result)
assert result['final_status']['reply']['result']['loaded'] is False
assert result['cleanup']['http_status']==200
print('RootHide physical service lifecycle verified and cleaned',result['pid'])
