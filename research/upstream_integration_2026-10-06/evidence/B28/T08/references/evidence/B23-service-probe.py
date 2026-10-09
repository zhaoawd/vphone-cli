from pathlib import Path
import plistlib
exec(Path('/private/tmp/vphone-b23-common.py').read_text())
label='com.vphone.B23.service-probe';job='/var/root/vphone-b23-api/service-probe.plist'
result={'target':target,'observations':rows}
try:
 result['bootstrap']=rpc_http('bootstrap.status')
 result['before']=rpc_http('services.status',{'label':label});assert result['before']['loaded'] is False
 body={'Label':label,'ProgramArguments':['/var/jb/bin/sh','-c','echo B23-service-probe; sleep 20'],'RunAtLoad':False,'KeepAlive':False,'StandardOutPath':'/var/root/vphone-b23-api/service-probe.log','StandardErrorPath':'/var/root/vphone-b23-api/service-probe.log'}
 host=Path('/private/tmp/vphone-b23-service-probe.plist');host.write_bytes(plistlib.dumps(body));assert ctl('file_put',path=job,load=str(host),perm='644')['ok']
 result['load']=rpc_http('services.load',{'paths':[job]});result['after_load']=rpc_http('services.status',{'label':label});assert result['after_load']['loaded'] is True
 result['start']=rpc_http('services.start',{'label':label})
 for _ in range(20):
  state=rpc_http('services.status',{'label':label})
  if state['running']:break
  time.sleep(.2)
 result['after_start']=state;assert state['running']
 result['stop']=rpc_http('services.stop',{'label':label,'force':True})
 result['complete']=True
finally:
 try:result['unload']=rpc_http('services.unload',{'paths':[job],'force':True});result['after_unload']=rpc_http('services.status',{'label':label});assert not result['after_unload']['loaded']
 except Exception as ex:result['cleanup_error']=repr(ex)
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b23-service-probe.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
