import pathlib,subprocess,json
out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');app=out/'TransportHarness.app';svc=app/'Contents/XPCServices/com.vphone.acceptance.t46.service.xpc';records=[]
for bundle,ident in [(svc,'com.vphone.acceptance.t46.service'),(app,'com.vphone.acceptance.t46.client')]:
 req=f'anchor apple generic and identifier "{ident}" and certificate leaf[subject.OU] = "3AA3QL69MQ"'
 for args in [['codesign','--verify','--strict','--deep','-R='+req,str(bundle)],['codesign','-dvvv',str(bundle)],['codesign','-d','--entitlements','-','--xml',str(bundle)]]:
  p=subprocess.run(args,text=True,capture_output=True,timeout=20);records.append({'argv':args,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr});print(p.returncode,p.stderr,flush=True)
  (out/'sign-verification.json').write_text(json.dumps(records,indent=2)+'\n')
  if p.returncode:raise SystemExit(p.returncode)
