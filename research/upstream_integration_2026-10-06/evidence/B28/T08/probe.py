#!/usr/bin/python3
"""Single-request future runtime collector; does not boot or deploy a VM."""
import argparse,datetime,hashlib,http.client,json,pathlib,stat,urllib.parse
p=argparse.ArgumentParser();p.add_argument('--url',required=True);p.add_argument('--token-file',required=True);p.add_argument('--request-file',required=True);p.add_argument('--output',required=True);p.add_argument('--allow-mutations',action='store_true');a=p.parse_args()
u=urllib.parse.urlparse(a.url)
if u.scheme!='http' or u.hostname not in ('localhost','127.0.0.1','::1') or u.username or u.password or u.query or u.fragment:raise SystemExit('Requires a local HTTP endpoint without credentials/query/fragment')
t=pathlib.Path(a.token_file)
if not stat.S_ISREG(t.lstat().st_mode) or t.stat().st_mode & 0o077:raise SystemExit('Token must be a private regular file')
token=t.read_text().strip()
if not token or '\r' in token or '\n' in token:raise SystemExit('Invalid token')
req=json.loads(pathlib.Path(a.request_file).read_text());method=req['method']
readonly={'services.status','services.list','services.print','processes.list','apps.foreground','bootstrap.status','device.info','logs.syslog'}
if method not in readonly and not (method=='display.rotation' and not req.get('params')) and not a.allow_mutations:raise SystemExit('Mutation requires --allow-mutations')
req.setdefault('id','b28-t08');body=json.dumps(req).encode();c=http.client.HTTPConnection(u.hostname,u.port or 80,timeout=30)
try:
 c.request('POST',u.path.rstrip('/')+'/v1/rpc',body=body,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'});r=c.getresponse();raw=r.read()
 result={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'request':req,'http_status':r.status,'response_sha256':hashlib.sha256(raw).hexdigest(),'response_bytes':len(raw),'reply':json.loads(raw)}
 text=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
 if token in text:raise SystemExit('Refusing credential disclosure')
 out=pathlib.Path(a.output);out.parent.mkdir(parents=True,exist_ok=True);out.write_text(text);out.chmod(0o600)
finally:c.close()
