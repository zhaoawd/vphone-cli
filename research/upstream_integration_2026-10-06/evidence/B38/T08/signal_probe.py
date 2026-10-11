"""区分服务信号路由、目标 TERM 行为和状态缓存；只操作新建的唯一测试服务。"""
import base64
import json
import plistlib
import time
import client
rows=[]
def call(m,p={}):
    r=client.rpc(m,p);rows.append(r);assert r['http_status']==200,r
    return r['reply'].get('result')
root=call('bootstrap.inspect')['jbroot'];label='com.vphone.B38.signal-probe';job=root+'/Library/LaunchDaemons/'+label+'.plist'
record={'observations':rows,'trials':[]}
try:
    assert call('services.status',{'label':label})['loaded'] is False
    data=plistlib.dumps({'Label':label,'UserName':'root','ProgramArguments':[root+'/usr/bin/sleep','60'],'RunAtLoad':False,'KeepAlive':False})
    call('files.write',{'path':job,'encoding':'base64','content':base64.b64encode(data).decode()})
    call('services.load',{'paths':[job]})
    for route in ['launchd-TERM','direct-TERM','launchd-KILL']:
        call('services.start',{'label':label})
        for _ in range(20):
            r=call('services.status',{'label':label})
            if r['running']:break
            time.sleep(.1)
        assert r['running'] and r['program']==root+'/usr/bin/sleep'
        pid=r['pid']; processes=call('processes.list',{'filter':'sleep'})['processes']
        proc=next(x for x in processes if x['pid']==pid);assert proc['ppid']==1 and proc['uid']==0
        trial={'route':route,'pid':pid,'before':proc}
        if route.startswith('launchd'):call('services.signal',{'label':label,'signal':'KILL' if route.endswith('KILL') else 'TERM','force':True})
        else:call('processes.kill',{'pid':pid,'signal':'TERM','force':True})
        for _ in range(10):
            status=call('services.status',{'label':label}); procs=call('processes.list',{'filter':'sleep'})['processes']
            trial.setdefault('samples',[]).append({'service':status,'process_present':any(x['pid']==pid for x in procs)})
            if not status['running'] and not trial['samples'][-1]['process_present']:break
            time.sleep(.2)
        record['trials'].append(trial)
        if trial['samples'][-1]['process_present']:
            # 仅清理本轮记录且再次核对身份的 PID。
            now=next(x for x in call('processes.list',{'filter':'sleep'})['processes'] if x['pid']==pid)
            assert now['start_time']==proc['start_time'] and now['executable']==proc['executable']
            call('processes.kill',{'pid':pid,'signal':'KILL','force':True});time.sleep(.2)
        call('services.stop',{'label':label,'force':True});time.sleep(.1)
finally:
    record['unload']=client.rpc('services.unload',{'paths':[job],'force':True})
    record['cleanup']=client.rpc('files.remove',{'path':job})
    client.save('signal-probe.json',record)
print([(r['route'],r['samples'][-1]['process_present'],r['samples'][-1]['service']['running']) for r in record['trials']])
