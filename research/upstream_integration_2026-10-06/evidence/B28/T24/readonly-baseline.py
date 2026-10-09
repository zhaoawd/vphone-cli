import subprocess,pathlib,json
out=pathlib.Path('/private/tmp/vphone-b28-t24');records=[]
for args in [['launchctl','print','system/com.vphone.cli.helper'],['security','authorizationdb','read','com.vphone.cli.helper.privileged'],['ls','-ld','/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist']]:
 p=subprocess.run(args,capture_output=True,text=True,timeout=10);records.append({'argv':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
(out/'system-baseline-readonly.json').write_text(json.dumps(records,indent=2)+'\n');print(json.dumps(records,indent=2))
