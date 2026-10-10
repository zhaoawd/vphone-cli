exec(open('/private/tmp/vphone-b30-t08/client.py').read())
import plistlib
jb='/var/containers/Bundle/Application/.jbroot-000114514191980C';label='com.vphone.B30.roothide-rewrite';job=jb+'/Library/LaunchDaemons/'+label+'.plist';p=root/'roothide-service-before.plist'
p.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/usr/bin/sleep','30'],'RunAtLoad':False,'KeepAlive':False,'StandardOutPath':'/tmp/vphone-b30-service.log','StandardErrorPath':'/tmp/vphone-b30-service.log'}))
result={'before':rpc('services.status',{'label':label})};assert not result['before']['reply']['result']['loaded']
try:
 result['put']=ctl('file_put',path=job,load=str(p),perm='644');assert result['put']['ok']
 result['load']=rpc('services.load',{'paths':[job]});assert result['load']['http_status']==200 and result['load']['reply']['result']['patched']==[job]
 result['readback']=ctl('file_get',path=job,save=str(root/'roothide-service-after.plist'))
 patched=plistlib.loads((root/'roothide-service-after.plist').read_bytes());assert patched['ProgramArguments']==[jb+'/usr/bin/sleep','30'] and patched['__Patched'] is True
 result['idempotent_load']=rpc('services.load',{'paths':[job]});assert result['idempotent_load']['reply']['result']['patched']==[]
 for method,params in [('services.start',{'label':label}),('services.status',{'label':label}),('services.signal',{'label':label,'signal':'TERM','force':True})]:result[method]=rpc(method,params);assert result[method]['http_status']==200
 assert result['services.status']['reply']['result']['running'] is True
 time.sleep(.2);result['after_signal']=rpc('services.status',{'label':label});assert not result['after_signal']['reply']['result']['running']
 result['restart']=rpc('services.start',{'label':label});assert result['restart']['http_status']==200
 result['stop']=rpc('services.stop',{'label':label,'force':True});assert result['stop']['http_status']==200
 result['remove']=rpc('services.remove',{'label':label,'force':True});assert result['remove']['http_status']==200
finally:
 result['unload']=rpc('services.unload',{'paths':[job],'force':True});result['after_unload']=rpc('services.status',{'label':label})
 assert not result['after_unload']['reply']['result']['loaded']
 result['observations']=rows;save('roothide-services.json',result)
print('RootHide plist rewrite, idempotent load, start/status/signal/restart/stop/remove/unload passed')
