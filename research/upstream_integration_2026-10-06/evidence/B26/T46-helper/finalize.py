from pathlib import Path
import json,hashlib,subprocess,shutil,datetime,struct
out=Path('/private/tmp/vphone-b26-t46-helper')
def sha(p):return hashlib.file_digest(open(p,'rb'),'sha256').hexdigest()
def tree(root):
 rows=[]
 for p in sorted(root.rglob('*')):
  if p.is_symlink():rows.append({'path':str(p.relative_to(root)),'kind':'symlink','target':str(p.readlink())})
  elif p.is_file():rows.append({'path':str(p.relative_to(root)),'kind':'file','size':p.stat().st_size,'mode':oct(p.stat().st_mode&0o777),'sha256':sha(p)})
 return rows
stable={'scope':'Final immutable copies of production modules/objects, both framework trees including symlink topology, and captured debug.yaml. Original manifest retained separately.','created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'files':tree(out/'stable')}
(out/'stable-input-manifest-final.json').write_text(json.dumps(stable,indent=2)+'\n')
orig=json.loads((out/'stable-input-manifest.json').read_text());assert all(sha(Path(f['copy']))==f['sha256'] for f in orig['files'])
(out/'signed-harness-manifest-final.json').write_text(json.dumps({'source_sha256':sha(out/'TransportHarness.swift'),'compiled_sha256':sha(out/'TransportHarness'),'files':tree(out/'TransportHarness.app')},indent=2)+'\n')
strip=[]
for label,p in [('compiled',out/'TransportHarness'),('client',out/'TransportHarness.app/Contents/MacOS/TransportHarness'),('service',out/'TransportHarness.app/Contents/XPCServices/com.vphone.acceptance.t46.service.xpc/Contents/MacOS/TransportHarness')]:
 q=out/(label+'-unsigned-comparison');shutil.copy2(p,q);args=['codesign','--remove-signature',str(q)];r=subprocess.run(args,text=True,capture_output=True);strip.append({'label':label,'argv':args,'exit_code':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'unsigned_sha256':sha(q)});assert r.returncode==0
compiled=(out/'compiled-unsigned-comparison').read_bytes();client=(out/'client-unsigned-comparison').read_bytes();service=(out/'service-unsigned-comparison').read_bytes()
assert client==service and len(compiled)==len(client)
offset=32;linkedit=None
for _ in range(struct.unpack_from('<I',compiled,16)[0]):
 cmd,size=struct.unpack_from('<II',compiled,offset)
 if cmd==0x19 and compiled[offset+8:offset+24].rstrip(b'\0')==b'__LINKEDIT':linkedit=offset+32
 offset+=size
assert linkedit is not None
assert compiled[:linkedit]==client[:linkedit] and compiled[linkedit+8:]==client[linkedit+8:]
comparison={'raw_unsigned_files':strip,'signed_client_service_equal':True,'compiled_vs_signed_only_difference':{'MachO_field':'LC_SEGMENT_64 __LINKEDIT.vmsize','field_file_offset':linkedit,'compiled_value':struct.unpack_from('<Q',compiled,linkedit)[0],'signed_value':struct.unpack_from('<Q',client,linkedit)[0]},'all_other_bytes_equal':True}
(out/'unsigned-main-comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
chosen={'normal':'normal-96e00c97','missing-ack':'missing-ack-9d00e206','disconnect':'disconnect-8644adf7','writer-failure':'writer-failure-994047d0'};cases=[]
for mode,label in chosen.items():
 d=json.loads((out/(label+'.json')).read_text());assert d['exit_code']==0
 result=next(e for e in d['events'] if e.get('mode')==mode and 'result' in e);finish=next(e for e in d['events'] if e.get('event')=='receiver_finished');elapsed=float(result['elapsed_seconds']);assert result['client_pid']!=result['service_pid'];assert d['logs'][0]['mode']=='0o600'
 if mode=='normal':assert result['result']=='success' and finish['success']=='true'
 else:assert result['result']=='failure'
 if mode=='missing-ack':assert 29<=elapsed<40 and 'Helper output not acknowledged' in result['error'] and 'Helper timed out' in result['error'] and finish['success']=='true'
 if mode=='disconnect':assert elapsed<5 and finish['success']=='true' and result['error']=='Transport invalidated' and any(e.get('event')=='transport_invalidated' for e in d['events'])
 if mode=='writer-failure':
  err=next(e for e in d['events'] if e.get('event')=='writer_finish_error');assert elapsed<5 and finish['success']=='false' and err['underlying_domain']=='NSPOSIXErrorDomain' and err['underlying_code']=='9' and d['logs'][0]['content']=='preserved\n';assert 'Helper output not acknowledged' in result['error'] and 'Helper timed out' not in result['error']
 cases.append({'mode':mode,'evidence':label+'.json','harness_exit':d['exit_code'],'client_pid':int(result['client_pid']),'service_pid':int(result['service_pid']),'operation_result':result['result'],'operation_seconds':elapsed,'wall_seconds':d['wall_seconds'],'receiver_finished':finish,'error':result.get('error'),'logs':d['logs']})
clean=json.loads((out/'process-final-readback.json').read_text());assert clean['matching_live_pids']==[]
summary={'task':'B26 T46 helper production-output transport fault matrix','status':'four_transport_cases_verified_root_mach_and_actual_store_pending','source_snapshot_head':orig['head'],'current_output_source_manifest':'current-source-manifest.json','immutable_input_manifest':'stable-input-manifest-final.json','harness_source_sha256':sha(out/'TransportHarness.swift'),'cases':cases,'identity':{'team':'3AA3QL69MQ','certificate_sha1':'5620D69F097306848C7CCD69F0B796A3C588BF28','certificate_type':'Apple Development (not Developer ID)','client_identifier':'com.vphone.acceptance.t46.client','service_identifier':'com.vphone.acceptance.t46.service','client_cdhash':'992c51d1cdfa229c3b45e87d9dc361a000423776','service_cdhash':'959417963bb2228e9eaa444f6e56f39fac9511ea','strict_requirement_readback':'sign-readback.json','audit_check':'Production VPhoneHelperListener.callerRejection invoked with the actual NSXPC auditToken before each accepted connection, plus setCodeSigningRequirement for both peers. A separate negative identity runtime case was not run.'},'production_implementation_reused':['VPhoneHelperService.verifyBundleStreaming/streaming','VPhoneHelperOutputChannel.finish (default timeout unchanged)','VPhoneHelperOutputAcknowledgement.wait (30 seconds)','VPhoneHelperOutputReceiver.helperDidFinishOutput','VPhoneLogWriter.write/finish','VPhoneHelperReply from VPhoneHelperClient.swift'],'fixture_boundaries':['application-scoped embedded NSXPCService; no privileged system Mach registration','verify returns transport-only fixture Data; authorize/install refuse','missing ACK and disconnect are injected after actual receiver writer completion','writer package initializer receives an actual O_RDONLY FileHandle; original stored NSError retrieved via idempotent finish for diagnostics'],'remaining_acceptance':['VPhoneHelperClient.request fixed .privileged Mach service and configured final CLI identity','VPhoneHelperDaemon root UID, authorization database registration and production listener/store combination','real Bundle install/verify and complete host/UI/VM lifecycle','original historical v1 helper is still unconfigured; reconstructed candidate is prepared_not_executed and cannot be called the original artifact'],'failures_retained':[{'stage':'first signing','reason':'snapshot followed framework relative symlinks; codesign reported ambiguous bundle format','evidence':'sign-readback-first-failed.json','repair':'framework-topology-repair.json; scratch only'},{'stage':'initial codesign requirement check','reason':'-R used a text argument where a requirement file was expected; corrected to -R=<requirement>','evidence':'sign-readback-v1.json'},{'stage':'v1/v2 disconnect harness','reason':'SIGTRAP in Harness.main proxy error block actor isolation check; nonisolated main alone did not resolve; explicit @Sendable error block resolved in final matrix','evidence':['disconnect-8c674476.json','disconnect-9dc5795b.json','TransportHarness-v1-disconnect.ips','TransportHarness-v2-disconnect.ips'],'production_modified':False,'actor_checks_disabled':False}],'cleanup':{'observed_exact_pids':len(clean['records']),'remaining_live_pids':[],'signals_sent':[]},'scope':{'SwiftPM':False,'production_source_modified':False,'production_app_modified':False,'system_helper_registered':False,'AMFI_changed':False,'TCC_changed':False,'VM_started':False,'UI_used':False,'legacy_v1_built_or_registered':False}}
(out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
(out/'summary.md').write_text('''# B26 T46 transport 结果

四行均使用临时app内嵌XPCService和真实不同PID，直接链接冻结的生产Service/Output/Writer/Reply；没有重写ACK状态机。双方正常Apple Development签名与严格要求通过，listener保留真实auditToken检查及逐消息要求，client保留server要求。

| 实验设置 | 结果 | 操作耗时 | 日志 |
| --- | --- | --- | --- |
| 正常ACK | receiver完成后返回成功 | 0.001303秒 | 两行75字节，0600，尾部精确一致 |
| 无ACK | 实际receiver持久化成功；生产默认30秒后返回明确未确认错误 | 30.012642秒 | 75字节/0600，文件完整不使操作成功 |
| XPC断线 | receiver完成后connection invalidated；返回Transport invalidated | 0.001547秒 | 75字节/0600；没有等待40秒客户端超时 |
| 只读FD写失败 | receiver负ACK；生产writer存储NSError为Cocoa512/底层POSIX9(EBADF)；操作明确未确认 | 0.006223秒 | 原10字节/0600文件与摘要保持 |

前3行日志SHA256为1749b7f2d93fdf4347756908497e12f37eb6605fc6abadea5386af8cfe1e4c89；写失败原文件SHA256为7ee0e7f63b9b65e302add82986c18196ecb8da0121575e4733219572eeac2712。每行harness退出0，故障行操作结果均为failure；判定还检查具体事件、错误与时间边界，未以exit0或任意failure替代故障验收。

本轮不经过生产Client.request的固定privileged Mach入口、root daemon注册或真实store。verify结果为只读fixture，authorize/install明确拒绝。独立拒绝身份运行行尚未执行。历史未配置v1实物未修改；重建方案仅prepared_not_executed。

首次framework签名失败、-R参数失败与两次harness断线SIGTRAP均保留。最终仅对临时Foundation proxy error回调显式@Sendable，没有关闭actor检查或修改生产实现。最终client/service移除签名后字节完全一致；与swiftc原输出的差异仅为__LINKEDIT.vmsize字段，其余字节一致。原始摘要及字段值已保全。

精确核验本轮20个client/service PID，均无残留，没有发送终止信号。完整结果见summary.json，冻结对象/框架输入见stable-input-manifest-final.json。
''')
print('final cases',len(cases),'strict assertions passed; stable files',len(stable['files']),'signed unsigned main equal',strip[1]['unsigned_sha256'],'no residual',not clean['matching_live_pids'])
