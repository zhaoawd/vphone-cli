import json,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
folder=root/'sources/VPhoneGuestComponents';out=root/'.build/virtiosound-validation';out.mkdir(exist_ok=True)
commands=[]
def run(command):
 commands.append(command);print(json.dumps(command),flush=True)
 subprocess.run(command,cwd=folder,check=True)
for component in ['Ring','Clock','Converter','Filter','Latency','Protocol']:
 run(['xcrun','--sdk','iphoneos','clang','-arch','arm64e','-miphoneos-version-min=26.0','-O1','-Wall','-Wextra','-Werror','-c','VirtIOSound/VPVirtIOSound'+component+'.c','-o',str(out/(component+'.o'))])
for harness,components in [('VirtIOSoundTests',['Protocol','Ring','Filter']),('VirtIOSoundClockTests',['Clock']),('VirtIOSoundConverterTests',['Converter']),('VirtIOSoundLatencyTests',['Latency'])]:
 binary=out/(harness+'-sanitized')
 run(['xcrun','--sdk','macosx','clang','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-fno-sanitize-recover=all','-IVirtIOSound','Tests/'+harness+'.c',*['VirtIOSound/VPVirtIOSound'+c+'.c' for c in components],'-o',str(binary)])
 run([str(binary)])
Path('/private/tmp/vphone-b11-audio-platform.json').write_text(json.dumps({'iphoneos_arm64e_algorithm_objects':6,'host_sanitized_harnesses_passed':4,'HAL_driver_linked':False,'guest_runtime_validated':False,'commands':commands},indent=2)+'\n')
