"""Diagnostic variant of the existing exact-CDHash helper; no persistent config."""
import datetime,os,subprocess,sys,traceback
from pathlib import Path
r=Path(__file__).resolve().parents[2]
base=Path(__file__).parent
cdhash='89b70a253cad2adea133b3e875519afaf72c5d17'
if os.geteuid()!=0:raise SystemExit('Native administrator authentication is required')
if sys.argv[1:]==['--worker']:
 print('[T32-attach] time='+datetime.datetime.now(datetime.timezone.utc).isoformat()+' euid='+str(os.geteuid()),flush=True)
 subprocess.run(['/bin/ps','-axo','pid,ppid,state,command'],stdout=subprocess.PIPE,check=True)
 sys.path.insert(0,'/Users/kolar/Library/Python/3.9/lib/python/site-packages')
 from amfidont import bypass_runtime as runtime
 runtime.load_persistent_config=lambda:{'paths':[],'cdhashes':[]}
 runtime.config_modified_time_state=lambda:(None,None)
 lldb=runtime.lldb
 debugger=lldb.SBDebugger.Create();debugger.SetAsync(False)
 target=debugger.CreateTarget('');error=lldb.SBError()
 process=target.AttachToProcessWithName(debugger.GetListener(),runtime.AMFID_PATH,False,error)
 print('[T32-attach] by-name error='+str(error)+' pid='+str(process.GetProcessID())+' state='+str(process.GetState()),flush=True)
 if not process or error.Fail():raise SystemExit(1)
 try:
  for symbol in ['-[AMFIPathValidator_macos validateWithError:]','-[AMFIPathValidator_macos isApple]']:
   bp=target.BreakpointCreateByName(symbol)
   print('[T32-attach] breakpoint='+symbol+' locations='+str(bp.GetNumLocations()),flush=True)
   if not bp.GetNumLocations():raise RuntimeError('Missing validation breakpoint')
  runtime.bypass_loop(process,target,paths=[],cdhashes=[cdhash],verbose=True,allow_all=False,spoof_apple=True)
 except BaseException:
  traceback.print_exc();raise
 finally:
  if process.GetState() not in [lldb.eStateExited,lldb.eStateDetached,lldb.eStateInvalid]:
   print('[T32-attach] detach='+str(process.Detach()),flush=True)
else:
 if sys.argv[1:]:raise SystemExit('Unsupported arguments')
 log=base/'host-allowance-diagnostic-worker.log'
 with log.open('ab') as stream:
  child=subprocess.Popen([sys.executable,'-u',str(Path(__file__).resolve()),'--worker'],stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
 print('Diagnostic exact-CDHash helper PID: '+str(child.pid),flush=True)
