from pathlib import Path
exec(Path('/private/tmp/vphone-b22-bound-common.py').read_text())
a=json.loads(Path('/private/tmp/vphone-b22-cache-fixed-artifact.json').read_text());assert health()['binary_hash']==a['sha256'];p=shell('ps -A -o pid=,ppid=,comm= | grep vphone-b21-api/vphoned').splitlines();proxy=next(int(x.split()[0]) for x in p if x.split()[1]=='1');worker=next(int(x.split()[0]) for x in p if x.split()[1]==str(proxy))
time.sleep(2)
result={'artifact_sha256':a['sha256'],'observations':rows,'websocket_files':[],'early_closes':[]}
try:
 result['fd_baseline']=shell('/var/root/vphone-b21-api/fd-probe '+str(worker))
 for size in [1048576]*3+[4194304]*2:
  reply=rpc('files.read',{'path':'/var/root/vphone-b21-transfer/'+str(size),'binary':True,'limit':size})
  data=base64.b64decode(reply['content']);result['websocket_files'].append({'expected':size,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()});rows[-1]['response']['result']['content']={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()};assert data==bytes(i%251 for i in range(size))
 for trial in range(20):
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
  c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/4194304',safe=''),headers={'Authorization':'Bearer '+token});r=c.getresponse();part=r.read(8192);r.close();c.close();result['early_closes'].append({'trial':trial,'status':r.status,'bytes_before_close':len(part)})
 h=health();dest='/var/root/vphone-b21-transfer/b22-cancelled-upload';assert not shell('test -e '+dest+' && echo EXISTS || true').strip()
 result['directory_before']=shell('ls -1A /var/root/vphone-b21-transfer')
 with socket.create_connection(('127.0.0.1',port),timeout=8) as s:
  request='PUT /v1/files/content?path='+urllib.parse.quote(dest,safe='')+' HTTP/1.1\r\nHost: 127.0.0.1:'+str(port)+'\r\nAuthorization: Bearer '+token+'\r\nX-Vphone-Instance-ID: '+h['instance_id']+'\r\nX-Vphone-Binary-Hash: '+h['binary_hash']+'\r\nContent-Length: 4194304\r\nConnection: close\r\n\r\n';s.sendall(request.encode()+bytes(i%251 for i in range(65536)))
 time.sleep(2)
 assert not shell('test -e '+dest+' && echo EXISTS || true').strip()
 result['directory_after']=shell('ls -1A /var/root/vphone-b21-transfer')
 result['fd_after']=shell('/var/root/vphone-b21-api/fd-probe '+str(worker));result['health_after']=health()
 result['complete']=result['directory_before']==result['directory_after'] and result['fd_after']==result['fd_baseline'];assert result['complete']
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-bound-close-ws.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
