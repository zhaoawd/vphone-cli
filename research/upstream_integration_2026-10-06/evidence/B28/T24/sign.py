import pathlib,subprocess,json
out=pathlib.Path('/private/tmp/vphone-b28-t24');cert='5620D69F097306848C7CCD69F0B796A3C588BF28';records=[]
def run(args):
 try:p=subprocess.run(args,capture_output=True,text=True,timeout=20)
 except subprocess.TimeoutExpired:
  records.append({'argv':args,'result':'timeout; stopped, keychain prompt possible; no bypass'});(out/'sign-readback.json').write_text(json.dumps(records,indent=2)+'\n');raise SystemExit('Signing stopped after 20 seconds; check whether normal keychain permission is required.')
 records.append({'argv':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});(out/'sign-readback.json').write_text(json.dumps(records,indent=2)+'\n');print(args[0:3],p.returncode,p.stderr[:250],flush=True);p.check_returncode()
helper=out/'com.vphone.cli.helper';app=out/'final-client.app'
run(['codesign','--force','--sign',cert,'--identifier','com.vphone.cli.helper',str(helper)])
# Normal app signing changes the main executable, plist seal and resource seal only.
# No --deep signing and no signing of vphone-vm, ldid, dylibs or other resources.
run(['codesign','--force','--sign',cert,'--identifier','com.vphone.cli',str(app)])
for path,ident in [(helper,'com.vphone.cli.helper'),(app,'com.vphone.cli')]:
 req=f'anchor apple generic and identifier "{ident}" and certificate leaf[subject.OU] = "3AA3QL69MQ"'
 run(['codesign','--verify','--strict','--deep','-R='+req,str(path)])
 run(['codesign','-dvvv',str(path)])
run([str(helper),'--check-configuration'])
