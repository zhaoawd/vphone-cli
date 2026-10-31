from pathlib import Path
import hashlib,json,os,secrets,subprocess,time
root=Path('/Users/kolar/github/vphone-cli');work=root/'.build/t52-real-20261021';out=work/'api-boot';vm=root/'.build/t51rt/lib/t52-v2'
cli=Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.cd529f26a150/VPhone.bundle/Contents/MacOS/vphone-cli')
assert hashlib.sha256(cli.read_bytes()).hexdigest()=='82f940ed219c41f928e7631989589f550d3c38e20360471a821881b062a42244'
helper=json.loads((work/'post-update-boot/helper-state.json').read_text());assert helper['state']=='running' and helper['deadline']>time.time()+180
binding=hashlib.sha256((vm/'launchpad.json').read_bytes()).hexdigest()
argv=[str(cli),'vm','launch','t52-v2','--library-root',str(vm.parent),'--headless','--api-listen','127.0.0.1:0','--expected-binding-sha256',binding,'--expected-core-bundle','2.6.2-local.cd529f26a150']
env=dict(os.environ,VPHONE_API_TOKEN=secrets.token_urlsafe(32),VPHONE_PYTHON=str(root/'.venv/bin/python3'))
record=dict(argv=argv,startedAt=time.time(),apiToken='ephemeral; not recorded',daemonUpdateRequested=False)
(out/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
with (out/'serial.log').open('wb') as log:
 child=subprocess.Popen(argv,cwd=vm,env=env,stdout=log,stderr=subprocess.STDOUT)
 record['wrapperPID']=child.pid;(out/'launch.json').write_text(json.dumps(record,indent=2)+'\n')
 try:status=child.wait(timeout=240)
 finally:
  if child.poll() is None:
   stop=subprocess.run([str(cli),'vm','stop','t52-v2','--library-root',str(vm.parent)],capture_output=True,text=True,timeout=50)
   (out/'cleanup-stop.json').write_text(json.dumps(dict(exitCode=stop.returncode,stdout=stop.stdout,stderr=stop.stderr),indent=2)+'\n')
 record.update(exitCode=child.returncode,finishedAt=time.time());(out/'launch-result.json').write_text(json.dumps(record,indent=2)+'\n')
print('Bound API-mode launch exited',status)
