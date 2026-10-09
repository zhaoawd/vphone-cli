import hashlib,json,shutil
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/research/upstream_integration_2026-10-06');s=Path('/private/tmp/vphone-b27');e=r/'evidence';dest=e/'B27';assert not dest.exists();dest.mkdir()
for p in sorted(s.iterdir()):
 if p.is_file():shutil.copyfile(p,dest/p.name)
shutil.copyfile('/private/tmp/vphone-b26-runtime/scoped.py',dest/'authorized-driver.py')
shutil.copyfile('/private/tmp/vphone-b26-runtime/scope.json',dest/'historical-prepared-scope.json')
summary={'batch':'B27','implementation_head':'b4e80c575950d768737234f9fcefc7fb7aff6081','documentation_base':'fd72938a47fbb8979eb44c39bddbf02a613ff514','source_changed':False,'authorization':'User explicitly authorized the single artifact CDHash 62a1f395413f6878c4de0042f6e77962aa2b1219; paths=[], allow_all=false, spoof_apple=true; no persistent SIP/AMFI setting change','newly_accepted':[],'selected_remaining':['T08','T24','T40','T46'],'vm_new':{'layout':'rootless','evidence':'Live serial and classic shell: /var/jb -> /private/preboot/B4491B383B98259E8F3C44F6517759621C73D19CF34DB50EF256FA2167A847570D1032BAB267ACA39383736C80029282/jb-vphone/procursus; successful .jbroot-* search in /private/var/containers/Bundle/Application returned no paths','suitable_for_actual_RootHide_acceptance':False,'guest_payload_auto_update':False,'classic_guest_connected':True,'modern_API_deployed':False,'first_boot':'stdin /dev/null; classic connected during framework shutdown; graceful timeout and forced stop, exit 0','second_boot':'independent FIFO serial input; live root readback, classic v1 connected; SIGINT classicAccepted, Guest stopped, exit 0'},'throughput':{'scope':'Real guest classic shell response to headless host only. Excludes UI, helper logging, console, rotation, panic and cancellation','byte_counts':[18944,303104,888000],'all_complete':True,'initial_failure':'awk unavailable, code 127; retained; rerun used shell builtin printf'},'AMFI_cleanup':{'normal_detach_observed':False,'driver_sigint':'did not exit','driver_sigterm':'exit 143; driver and debugserver absent','kickstart_k':'OS refused with exit 150 while SIP engaged','amfid_TERM':'did not replace PID','amfid_KILL_then_launchd_start':'new PID 92181, PPID 1, STAT Ss','configuration_files':'paths and cdhashes remain zero bytes','post_driver_cleanup_help_exit':0,'fresh_amfid_help_exit':0,'full_revocation_verified':False,'limitation':'Same artifact --help still exits 0 after driver cleanup and fresh amfid. Cause undetermined; cannot claim original AMFI refusal restored. No host reboot or cache manipulation performed.'},'preservation':{'config_and_host_guest_payload_sha256':'unchanged','Disk_img_full_hash':False,'disk_released':True,'other_vm_pid_35668':'preserved'},'remaining':{'T08':'Actual RootHide sample/service; status 144 and partial rotation causes undetermined','T24':'Full actual TCC responsibility chain, historical helper v1 actual XPC matrix, Python/PATH closure','T40':'External toolchain/CFW closure, trusted binding/receipt, four-layer upgrade/rollback, full 64GiB archive round trip','T46':'Production privileged helper/Client combination; full UI, panic/cancel/rotation and end-to-end throughput'},'tooling_failures':['First capabilities-2 invocation lacked its request file; no VM mutation; request copied and retried successfully','Initial ps without escalation was denied by sandbox; later scoped ps used escalation']}
(e/'B27-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
new={
'T08':' B27在用户单哈希AMFI授权后启动vm-new，以串口和classic shell实际读回：/var/jb指向Preboot的jb-vphone/procursus；对/private/var/containers/Bundle/Application的.jbroot-*搜索退出0且无结果，bootstrap记录不存在。该样本采用rootless布局，不满足实际RootHide验收。没有部署现代API或自动更新guest；状态144和部分旋转未生效的原因未查明。',
'T24':' B27用户已明确授权冻结b4e80c57单一CDHash；--help退出0，实际vm-new无界面启动、classic连接和最终正常停机通过。完整TCC责任链及历史v1实际XPC矩阵仍未验。临时驱动和debugserver已退出，新系统amfid正常；正常detach未完成。清理及新amfid后同工件--help仍退出0，原因未查明，未证明原AMFI拒绝恢复。',
'T40':' B27冻结宿主Bundle实际启动既有未绑定vm-new，配置与宿主.vphoned.signed摘要保持，未自动更新guest。本次未创建可信binding/receipt，不能替代可信store绑定启动或四层来源矩阵。磁盘剩余约18.6GiB，完整64GiB归档往返仍未执行。',
'T46':' B27新增真实guest classic shell到无界面host的三组有界输出：18944/303104/888000字节逐字节及SHA一致，退出0、无截断、无超时；首轮缺awk退出127已保留，改用shell内建printf重跑通过。第二次VM停机返回classicAccepted、Guest stopped及进程退出0。该结果不覆盖UI、helper日志、console、panic/取消/轮换或端到端吞吐。'}
p=r/'tasks.json';t=json.loads(p.read_text())
for x in t['tasks']:
 if x['id'] not in new:continue
 x['current_result']+=new[x['id']]
 x['verification_evidence']+=['evidence/B27-summary.json','evidence/B27-evidence-manifest.json']
 x['B27_implementation_head']=summary['implementation_head']
 if x['id']=='T08':x['remaining_work']=['实际RootHide客户机服务验收；vm-new已实际确认rootless，不满足该项前提','services.start状态144及部分旋转未生效，原因未查明']
 if x['id']=='T24':x['remaining_work'][0]='完整TCC负责应用链实际验收，包括直接CLI与Launchpad→launcher→可信store路线；B27已执行单哈希授权下的无界面VM读回，未验完整TCC链'
t['latest_validation_limitation']='B27实际确认vm-new为rootless；真实classic通道有界输出和最终正常停机通过，不替代UI/helper端到端验收。四项仍未完成。临时驱动及debugserver已清理，新amfid正常；同工件--help仍0，原AMFI拒绝恢复未证实。'
t['B27_execution_state']={'implementation_head':summary['implementation_head'],'newly_accepted':[],'accepted_total':8,'required_remaining':38,'optional_deferred':1,'selected_remaining':summary['selected_remaining'],'AMFI_scope_status':'authorized_executed_driver_removed_fresh_amfid_running_full_revocation_unverified'}
p.write_text(json.dumps(t,ensure_ascii=False,indent=2)+'\n')
p=r/'capability_ledger.json';c=json.loads(p.read_text())
for x in c:
 if x['id'] not in new:continue
 task=next(y for y in t['tasks'] if y['id']==x['id']);x['current_result']=task['current_result'];x['remaining_work']=task['remaining_work'];x['evidence']+=['evidence/B27-summary.json','evidence/B27-evidence-manifest.json'];x['B27_implementation_head']=summary['implementation_head']
p.write_text(json.dumps(c,ensure_ascii=False,indent=2)+'\n')
p=r/'README.md';txt=p.read_text().replace('当前验收结果见末尾 B26 记录','当前验收结果见末尾 B27 记录')
txt+='''

## B27 结果（2026-10-09）

用户明确授权冻结源码`b4e80c57`的VM单一CDHash `62a1f395413f6878c4de0042f6e77962aa2b1219`，范围为`paths=[]`、`allow_all=false`、`spoof_apple=true`。本轮没有修改持久SIP/AMFI设置。没有新增整项验收，T08/T24/T40/T46仍未完成。

`vm-new`已通过实际客户机串口及classic shell确认采用rootless布局。`/var/jb`指向Preboot下的`jb-vphone/procursus`；在`/private/var/containers/Bundle/Application`搜索`.jbroot-*`，退出0且无结果；`/private/var/db/vphoned/bootstrap.json`及`/cores/.vphoned-boostrap-completed`不存在。该样本不满足T08实际RootHide客户机验收的前提。服务状态144和部分旋转未生效的原因仍未查明。

冻结VM的授权后`--help`退出0。首次无界面启动的标准输入为`/dev/null`，classic在框架停机请求期间连接，最终停机超时后强制停止、进程退出0。第二次通过独立FIFO提供串口输入；classic v1连接后实际读回布局，停机记录`classicAccepted`、`Guest stopped`及进程退出0。启动均使用`--no-vphoned-update`；未部署现代API，配置及宿主`.vphoned.signed`摘要保持。现有vm-2607未停止，vm-new的Disk.img已无打开句柄。

真实guest classic shell到无界面host的三组输出分别为18944、303104、888000字节，逐字节及SHA一致，均退出0、无截断、无超时；请求往返约0.0127、0.0361、0.0876秒。初次客户机缺少awk、退出127，失败保留；最终改用shell内建printf。这仅验证该通道的有界输出完整性及一次测量，不替代UI、helper日志、console、panic/取消/轮换或端到端吞吐验收。完整TCC责任链、历史helper实际XPC矩阵、可信binding/receipt及四层升级回退矩阵保持未完成。可用空间约18.6GiB，完整64GiB归档往返未执行。

AMFI清理未观察到正常detach：SIGINT后驱动未退出，SIGTERM后退出143，驱动及debugserver均不存在。`kickstart -k`被系统以150拒绝；TERM没有替换原amfid PID。随后仅结束本轮附加过的系统amfid，launchd启动新PID92181，独立核对PPID1、STAT Ss及系统服务running。空配置文件仍为空。驱动清理后及新amfid下，同工件`--help`仍返回0，原因未查明；不能据此宣称原AMFI拒绝已恢复或放行结果已完全撤销。没有重启宿主或执行缓存修改，失败记录均保留。

本轮仅新增运行证据与台账，没有修改产品源码。证据入口：[B27-summary.json](evidence/B27-summary.json)、[B27-evidence-manifest.json](evidence/B27-evidence-manifest.json)。
'''
p.write_text(txt)
files=sorted([p for p in dest.iterdir() if p.is_file()]+[e/'B27-summary.json']);manifest={'schema_version':1,'batch':'B27','files':[{'path':str(p.relative_to(r)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]};(e/'B27-evidence-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'files':len(files),'bytes':sum(x['bytes'] for x in manifest['files']),'newly_accepted':[]},ensure_ascii=False))
