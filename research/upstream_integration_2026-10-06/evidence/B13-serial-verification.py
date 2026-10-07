import json,os,subprocess,time
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');e=os.environ.copy()
for k in list(e):
 if k.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_')):del e[k]
e['DYLD_FRAMEWORK_PATH']='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:/Applications/Xcode.app/Contents/SharedFrameworks'
e['DYLD_LIBRARY_PATH']='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib'
commands=[('serial-swift',['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper','--test-bundle-path',str(r/'.build/debug/vphone-cliPackageTests.xctest/Contents/MacOS/vphone-cliPackageTests'),'--testing-library','swift-testing','--no-parallel','--skip','FirmwareIntegrationTests']),('tar-memory',[str(r/'.venv/bin/python3'),'-B','scripts/check_tar_pipe_memory.py']),('guest-components',['make','test_guest_components'])];rows=[]
for n,c in commands:
 p=Path('/private/tmp/vphone-b13-'+n+'.log');assert not p.exists();started=time.time()
 with p.open('w') as f:
  f.write('COMMAND '+json.dumps(c)+'\n');f.flush();result=subprocess.run(c,cwd=r,env=e,stdout=f,stderr=subprocess.STDOUT)
 rows.append({'name':n,'command':c,'returncode':result.returncode,'elapsed_seconds':time.time()-started,'log':str(p)})
 if result.returncode:break
p=Path('/private/tmp/vphone-b13-serial-results.json');assert not p.exists();p.write_text(json.dumps(rows,indent=2)+'\n');print(rows)
