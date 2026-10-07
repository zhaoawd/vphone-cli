import base64,hashlib,http.client,json,re,socket,time
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(90);s.connect(str(main/'vm-new/vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>8*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
call('capabilities')
call('rpc',method='device.screen',params={})
call('rpc',method='screen.unlock',params={'timeout':10})
call('rpc',method='device.screen',params={})
call('key',name='power');time.sleep(1)
call('rpc',method='device.screen',params={})
call('rpc',method='screen.unlock',params={'timeout':10})
call('rpc',method='device.screen',params={})
call('rpc',method='system.shutdown',params={'force':False})
call('rpc',method='apps.launch',params={'bundle_id':'com.apple.Preferences'})
call('rpc',method='apps.foreground',params={})
call('rpc',method='apps.launch',params={'bundle_id':'com.apple.springboard'})
call('rpc',method='device.screen',params={})
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b10-restart-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b10-restart-token').read_text();probes=[]
for case,auth in [('missing',None),('incorrect','b13-incorrect-token'),('correct',token)]:
 conn=http.client.HTTPConnection('127.0.0.1',port,timeout=10);headers={}
 if auth:headers['Authorization']='Bearer '+auth
 conn.request('GET','/v1/health',headers=headers);resp=conn.getresponse();body=resp.read();probes.append({'case':case,'status':resp.status,'body':body.decode(errors='replace')});conn.close()
output=Path('/private/tmp/vphone-b13-api-acceptance.json');assert not output.exists();text=json.dumps({'observations':rows,'token_probes':probes,'frozen_host_source':'2387af20','startup_worker_source_deployed':False,'password_supplied':False,'configuration_changed':False},indent=2)+'\n';assert token not in text;output.write_text(text)
print({'rpc_observations':[{'request':r['request']['t'], 'method':r['request'].get('method'),'response':r['response']} for r in rows if r['request']['t']!='capabilities'],'token_statuses':[(p['case'],p['status']) for p in probes]})
