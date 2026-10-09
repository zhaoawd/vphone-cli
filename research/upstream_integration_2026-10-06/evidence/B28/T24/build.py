import pathlib,subprocess,json
out=pathlib.Path('/private/tmp/vphone-b28-t24');swift='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc';sdk='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk'
base=[swift,'-swift-version','6','-package-name','vphone_cli','-sdk',sdk,'-target','arm64-apple-macosx15.0','-module-cache-path',str(out/'module-cache'),'-I',str(out/'Modules'),'-I',str(out/'inputs/archive-slice'),'-Xcc','-I','-Xcc',str(out/'inputs/archive-slice'),'-F',str(out/'inputs/archive-slice'),'-g']
steps=[]
def run(name,args):
 (out/(name+'-argv.json')).write_text(json.dumps(args,indent=2)+'\n');p=subprocess.run(args,capture_output=True,text=True,timeout=120);(out/(name+'.stdout')).write_text(p.stdout);(out/(name+'.stderr')).write_text(p.stderr);steps.append({'step':name,'returncode':p.returncode});(out/'build-results.json').write_text(json.dumps(steps,indent=2)+'\n');print(name,p.returncode,p.stderr[:2000],flush=True);p.check_returncode()
for module in ['VPhoneArchiveKit','VPhoneBundleStore','VPhoneHelperKit']:
 sources=sorted((out/'source/sources'/module).rglob('*.swift'))
 args=base+['-module-name',module,'-parse-as-library','-whole-module-optimization','-emit-object','-emit-module','-emit-module-path',str(out/'Modules'/(module+'.swiftmodule'))]+[str(p) for p in sources]+['-o',str(out/'inputs'/(module+'.o'))]
 run(module,args)
args=base+['-module-name','VPhoneHelperEntry',str(out/'source/sources/VPhoneHelperEntry/main.swift')]+[str(p) for p in sorted((out/'inputs').glob('*.o'))]+['-framework','libarchive','-framework','Foundation','-framework','Security','-framework','ServiceManagement','-lz','-lbz2','-liconv','-lxml2','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(out/'Legacy-Helper-Info.proposed.plist'),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__launchd_plist','-Xlinker',str(out/'Legacy-Helper-Launchd.proposed.plist'),'-o',str(out/'legacy-v1-built')]
run('link',args)
