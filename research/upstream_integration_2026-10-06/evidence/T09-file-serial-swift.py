import os,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
env=os.environ.copy()
for name in list(env):
 if name.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_')):del env[name]
env.setdefault('CLANG_MODULE_CACHE_PATH',str(root/'.build/test-module-cache'))
env.setdefault('SWIFT_MODULECACHE_PATH',str(root/'.build/test-module-cache'))
command=['swift','test','--disable-sandbox','--cache-path','.build/test-cache','--skip','FirmwareIntegrationTests','--no-parallel']
print(' '.join(command),flush=True)
with open('/private/tmp/vphone-t09-file-serial-swift-20261007.log','w') as output:
 result=subprocess.run(command,cwd=root,env=env,stdout=output,stderr=subprocess.STDOUT)
raise SystemExit(result.returncode)
