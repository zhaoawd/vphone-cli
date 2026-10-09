from pathlib import Path
exec(Path('/private/tmp/vphone-b23-common.py').read_text())
result={'target':target,'observations':rows,'matrix':[]}
def call(method,params={}):
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=30)
 try:
  c.request('POST','/v1/rpc',body=json.dumps({'method':method,'params':params,'id':'b23'}),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'});r=c.getresponse();data=r.read();reply=json.loads(data)
  row={'method':method,'params':params,'status':r.status,'response_bytes':len(data),'response_sha256':hashlib.sha256(data).hexdigest()}
  if method!='screen.screenshot':row['reply']=reply
  rows.append(row);return reply
 finally:c.close()
result['baseline']=rpc_http('display.rotation');result['frontmost_before']=rpc_http('apps.foreground')
try:
 result['unlock']=call('screen.unlock');result['unlock_orientation']=call('display.rotation_lock',{'locked':False})
 for app in ['com.apple.Preferences','com.apple.mobilesafari']:
  opened=call('apps.launch',{'bundle_id':app});time.sleep(.7)
  for degrees in [0,90,270,180]:
   change=call('display.rotation',{'orientation':str(degrees)});time.sleep(.4);actual=call('display.rotation');shot=call('screen.screenshot')
   data=base64.b64decode(shot['result']['data']);saved={k:v for k,v in shot['result'].items() if k!='data'}
   dest=Path('/private/tmp/vphone-b23-'+app.split('.')[-1]+'-'+str(degrees)+'.jpeg');dest.write_bytes(data);saved.update({'sha256':hashlib.sha256(data).hexdigest(),'path':str(dest)})
   result['matrix'].append({'app':app,'opened':opened,'requested':degrees,'change':change,'actual':actual,'screenshot':saved})
finally:
 result['restore_rotation']=call('display.rotation',{'orientation':str(result['baseline']['degrees'])});result['restore_lock']=call('display.rotation_lock',{'locked':result['baseline']['locked']})
 result['restore_app']=call('apps.launch',{'bundle_id':result['frontmost_before']['bundle_id']})
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b23-rotation-apps.json').write_text(text)
print([{'app':x['app'],'requested':x['requested'],'change':x['change'],'actual':x['actual'],'dimensions':[x['screenshot']['width'],x['screenshot']['height']]} for x in result['matrix']])
