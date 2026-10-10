exec(open('/private/tmp/vphone-b30-t08/client.py').read())
import base64,hashlib
result={'diagnostic_library_enabled':True,'baseline':rpc('display.rotation'),'foreground_before':rpc('apps.foreground'),'matrix':[]}
try:
 result['unlock']=rpc('screen.unlock');result['unlock_rotation']=rpc('display.rotation_lock',{'locked':False})
 for app in ['com.apple.Preferences','com.apple.mobilesafari']:
  opened=rpc('apps.launch',{'bundle_id':app});time.sleep(.7)
  info=rpc('apps.info',{'bundle_id':app});save('app-info-'+app+'.json',info)
  for degrees in [0,90,270,180]:
   change=rpc('display.rotation',{'orientation':str(degrees)});t=time.monotonic();samples=[]
   for targetTime in [0,.25,.5,1,2]:
    pause=targetTime-(time.monotonic()-t)
    if pause>0:time.sleep(pause)
    samples.append({'actual_elapsed_after_setter_response':time.monotonic()-t,'rotation':rpc('display.rotation')})
   front=rpc('apps.foreground');shot=rpc('screen.screenshot');details=shot['reply'].get('result',{});image=details.pop('data',None)
   if image:
    data=base64.b64decode(image);name='rotation-'+app.split('.')[-1]+'-'+str(degrees)+'.jpeg';(root/name).write_bytes(data);details.update(saved_file=name,sha256=hashlib.sha256(data).hexdigest())
   result['matrix'].append({'app_requested':app,'opened':opened,'requested':degrees,'change':change,'samples':samples,'frontmost':front,'screenshot':shot})
finally:
 base=result['baseline']['reply']['result'];result['restore_rotation']=rpc('display.rotation',{'orientation':str(base['degrees'])});result['restore_lock']=rpc('display.rotation_lock',{'locked':base['locked']})
 front=result['foreground_before']['reply']['result']
 if front.get('verified') and front.get('bundle_id')!='com.apple.springboard':result['restore_foreground']=rpc('apps.launch',{'bundle_id':front['bundle_id']})
 else:result['restore_home']=ctl('home')
 result['foreground_after']=rpc('apps.foreground');result['observations']=rows;save('rotation-matrix.json',result)
 print(ctl('file_get',path='/var/root/vphone-b29-api/b30-rotation.log',save=str(root/'rotation-trace.log')))
for row in result['matrix']:print(row['app_requested'],row['requested'],row['change']['http_status'],row['samples'][-1]['rotation']['reply'],row['screenshot']['reply'].get('result',{}).get('saved_file'))
