from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
try:
 for i in range(5):rpc('screen.screenshot')
 for i in range(5):rpc('services.status',{'label':'com.apple.SpringBoard'});rpc('processes.list',{'filter':'Preferences'})
 rpc('display.rotation');rpc('location.current')
 r=ctl('file_put',path='/var/root/vphone-b21-transfer/nonutf8',data_b64=base64.b64encode(b'\xff\xfe\x00').decode());assert r['ok']
 # Invalid text is explicitly rejected, binary mode remains usable.
 result['non_utf8_text']=ctl('rpc',method='files.read',params={'path':'/var/root/vphone-b21-transfer/nonutf8'})
 result['non_utf8_binary']=rpc('files.read',{'path':'/var/root/vphone-b21-transfer/nonutf8','binary':True})
 result['health']=health();result['completed']=True
finally:
 text=json.dumps(result,ensure_ascii=False,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-rpc-rest.json').write_text(text)
print('completed')
