"""自动服务验收：读取启动后的状态和 plist，通过 SSH socket 触发 demand job；不调用 load/start/helper。"""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import socket
import struct
import sys
import time
import client
output_name = sys.argv[1] if len(sys.argv)>1 else "automatic-bootstrap.json"

def ok(method,params={}):
    r=client.rpc(method,params);assert r['http_status']==200,r
    return r['reply']['result']
root=ok('bootstrap.inspect')['jbroot']
records={'bootstrap_root':root,'services':{},'jobs':{}}
for label in ['wiki.qaq.irisind','com.openssh.sshd','com.vphone.vphoned-api']:
    records['services'][label]=ok('services.status',{'label':label})
    assert records['services'][label]['loaded'], label
for name in ['wiki.qaq.irisind','com.openssh.sshd']:
    raw=ok('files.read',{'path':root+'/Library/LaunchDaemons/'+name+'.plist','binary':True})
    data=base64.b64decode(raw['content'])
    records['jobs'][name]=plistlib.loads(data)
for name in ['vphoned','vphoned-api']:
    r=client.rpc('files.read',{'path':'/var/root/Library/Caches/'+name,'binary':True})
    records['cache_'+name]={'http_status':r['http_status']}
    if r['http_status']==200:
        data=base64.b64decode(r['reply']['result']['content']); records['cache_'+name]['sha256']=hashlib.sha256(data).hexdigest()
# SSH 本轮只读取服务 banner，不认证或执行命令。
port=int(re.search(r'\[api\] proxy listening on http://127.0.0.1:(\d+)',(client.run/'console-redacted.log').read_text())[1])
key=base64.b64encode(b'B38-SSH-banner!!').decode()
s=socket.create_connection(('127.0.0.1',port),timeout=10)
s.sendall(('GET /v1/ports/22 HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer '+(client.run/'token').read_text()+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
raw=b''
while b'\r\n\r\n' not in raw: raw+=s.recv(4096)
header,buf=raw.split(b'\r\n\r\n',1)
assert b' 101 ' in header,header
while len(buf)<2: buf+=s.recv(4096)
length=buf[1]&127;pos=2
if length==126:
    while len(buf)<4:buf+=s.recv(4096)
    length=struct.unpack('!H',buf[2:4])[0];pos=4
assert length<4096
while len(buf)<pos+length:buf+=s.recv(4096)
records['ssh_banner']=buf[pos:pos+length].decode()
s.close();assert records['ssh_banner'].startswith('SSH-2.0-OpenSSH_'),records
records['api_health']=client.rpc()['reply']
expected=json.loads((client.evidence/'default-artifact.json').read_text())
assert records['api_health']['binary_hash']==expected['api_sha256']
assert records['api_health']['bootstrap_startup_enabled'] is True
assert records['api_health']['camera_publisher_enabled'] is False
assert records['api_health']['cache_path']=='/var/root/Library/Caches/vphoned-api'
records['processes']=ok('processes.list',{'filter':'vphoned'})
records['classic_roundtrip']=client.ctl('app_list',filter='running')
assert records['classic_roundtrip']['ok']
records['automatic_loading_verified']=True
client.save(output_name,records)
print(json.dumps({'automatic_loading_verified':True,'ssh_banner':records['ssh_banner'],'api_sha256':records['api_health']['binary_hash'],'services':records['services']},indent=2))
