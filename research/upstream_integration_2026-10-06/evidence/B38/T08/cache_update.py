"""同摘要显式 API 更新：实际 proxy/worker 重启，classic 缓存保持，退出前恢复 API 缓存原状态。"""
import base64
import hashlib
import http.client
import json
from pathlib import Path
import re
import time
import urllib.parse
import client

record={};cache='/var/root/Library/Caches/vphoned-api'
markers=['/var/root/Library/Caches/vphoned.api-v2','/var/root/Library/Caches/vphoned.api-v2.pending']
baselines={}
def rpc(m,p={}):
    r=client.rpc(m,p);assert r['http_status']==200,r
    return r['reply']['result']
def file(path):
    r=client.rpc('files.read',{'path':path,'binary':True,'limit':64*1024**2})
    if r['http_status']==400:return None
    assert r['http_status']==200 and r['reply']['result']['truncated'] is False,r
    return base64.b64decode(r['reply']['result']['content'])
def classic():return hashlib.sha256(file('/var/root/Library/Caches/vphoned')).hexdigest()
for path in [cache,*markers]:
    baselines[path]=file(path)
    assert baselines[path] is None,'expected no preexisting API cache or markers; refusing overwrite'
health=client.rpc()['reply'];record['health_before']=health
record['classic_before']=classic()
image=client.code/'.build/guest/api/vphoned';payload=image.read_bytes();sha=hashlib.sha256(payload).hexdigest()
assert sha==health['binary_hash']
port=int(re.search(r'\[api\] proxy listening on http://127.0.0.1:(\d+)',(client.run/'console-redacted.log').read_text())[1])
try:
    client.check()
    conn=http.client.HTTPConnection('127.0.0.1',port,timeout=60)
    conn.request('PUT','/v1/files/content?'+urllib.parse.urlencode({'path':cache+'.next','mode':'755'}),payload,headers={'Authorization':'Bearer '+(client.run/'token').read_text(),'Content-Type':'application/octet-stream','X-Vphone-Instance-ID':health['instance_id'],'X-Vphone-Binary-Hash':sha})
    response=conn.getresponse();record['upload']={'status':response.status,'reply':json.loads(response.read())};conn.close()
    assert record['upload']['status']==200
    assert hashlib.sha256(file(cache+'.next')).hexdigest()==sha
    record['apply_update']=rpc('agent.apply_update',{'sha256':sha})
    assert record['apply_update']['restarting'] is True
    attempts=[]
    for _ in range(60):
        time.sleep(.5)
        try:
            h=client.rpc();attempts.append(h)
            if h['http_status']==200 and h['reply']['instance_id']!=health['instance_id']:
                record['health_after']=h['reply'];break
        except Exception as e:attempts.append({'exception':str(e)})
    record['restart_attempts']=attempts
    assert record.get('health_after') and record['health_after']['binary_hash']==sha
    record['processes_after']=rpc('processes.list',{'filter':'vphoned-api'})
    rows=record['processes_after']['processes']
    assert len([r for r in rows if r['executable'].endswith('/Library/Caches/vphoned-api')])==2,rows
    assert file(markers[0])==sha.encode() and file(markers[1]) is None
    record['confirmed_marker_sha256']=hashlib.sha256(file(markers[0])).hexdigest()
    record['classic_after']=classic();assert record['classic_after']==record['classic_before']
    record['classic_roundtrip']=client.ctl('app_list',filter='running');assert record['classic_roundtrip']['ok']
    record['complete']=True
except BaseException as e:
    record['failure']={'type':type(e).__name__,'message':str(e)};raise
finally:
    record['cleanup']={}
    for path in [cache,cache+'.next',*markers]:
        try:record['cleanup'][path]=client.rpc('files.remove',{'path':path})
        except Exception as e:record['cleanup'][path]={'exception':str(e)}
    client.save('cache-update.json',record)
print('API proxy/worker restart and cache confirmation verified; classic cache unchanged')
