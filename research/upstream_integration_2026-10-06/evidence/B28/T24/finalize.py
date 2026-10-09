import pathlib,subprocess,json,shutil,hashlib,plistlib,re,struct
out=pathlib.Path('/private/tmp/vphone-b28-t24');repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');app=out/'final-client.app';helper=out/'com.vphone.cli.helper'
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
def manifest(root):return [{'path':str(p.relative_to(root)),'sha256':sha(p),'mode':oct(p.stat().st_mode&0o7777),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()]
unsigned={}
for name,src in [('client',app/'Contents/MacOS/vphone-cli'),('helper',helper)]:
 dst=out/(name+'-after-unsigned');shutil.copy2(src,dst);subprocess.run(['codesign','--remove-signature',str(dst)],capture_output=True,check=True);before_path=out/(name+'-before-unsigned');before=sha(before_path);after=sha(dst)
 a=bytearray(before_path.read_bytes());b=bytearray(dst.read_bytes());assert len(a)==len(b);cursor=32;linkedit=None
 for _ in range(struct.unpack_from('<I',a,16)[0]):
  cmd,size=struct.unpack_from('<II',a,cursor)
  if cmd==0x19 and bytes(a[cursor+8:cursor+24]).split(b'\0')[0]==b'__LINKEDIT':linkedit=cursor+32
  cursor+=size
 assert linkedit is not None
 bv=struct.unpack_from('<Q',a,linkedit)[0];av=struct.unpack_from('<Q',b,linkedit)[0]
 a[linkedit:linkedit+8]=bytes(8);b[linkedit:linkedit+8]=bytes(8);assert a==b
 unsigned[name]={'before_sha256':before,'after_sha256':after,'raw_equal':before==after,'signature_size_related_macho_field':{'name':'LC_SEGMENT_64 __LINKEDIT.vmsize','offset':linkedit,'before':bv,'after':av},'all_other_unsigned_bytes_equal':True,'comparison_excluding_vmsize_sha256':hashlib.sha256(a).hexdigest()}
original=json.loads((out/'client-original-manifest.json').read_text());current=manifest(repo/'.build/vphone-cli.app');assert original['files']==current
before={f['path']:f for f in original['files']};after={f['path']:f for f in manifest(app)};changed=[k for k in sorted(set(before)|set(after)) if before.get(k)!=after.get(k)];assert set(changed)=={'Contents/Info.plist','Contents/MacOS/vphone-cli'}
source=json.loads((out/'source-manifest.json').read_text());original_helper=pathlib.Path(source['original_adhoc_path']);assert sha(original_helper)==source['original_adhoc_expected_sha256']
for f in source['historical_source_files']:assert sha(out/'source'/f['path'])==f['sha256']
archive_repo=repo/'.build/checkouts/libarchive.xcframework';archive_source=archive_repo/'Sources/ArchiveKit/ArchiveKit.swift';shutil.copy2(archive_source,out/'inputs/ArchiveKit-source.swift');source['external_archivekit_source']={'checkout':str(archive_repo),'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=archive_repo,text=True).strip(),'path':'Sources/ArchiveKit/ArchiveKit.swift','git_blob':subprocess.check_output(['git','rev-parse','HEAD:Sources/ArchiveKit/ArchiveKit.swift'],cwd=archive_repo,text=True).strip(),'sha256':sha(archive_source)};(out/'source-manifest.json').write_text(json.dumps(source,indent=2)+'\n')
records=json.loads((out/'sign-readback.json').read_text());artifacts=[]
for p in [helper,app/'Contents/MacOS/vphone-cli']:
 display=next(r['stderr'] for r in records if r['argv'][0:2]==['codesign','-dvvv'] and ((r['argv'][-1]==str(app)) if p.name=='vphone-cli' else r['argv'][-1]==str(helper)))
 artifacts.append({'path':str(p),'sha256':sha(p),'cdhash':re.search(r'^CDHash=(.+)$',display,re.M).group(1),'team':'3AA3QL69MQ','signing_identity_sha1':'5620D69F097306848C7CCD69F0B796A3C588BF28','certificate_kind':'Apple Development','strict_deep_requirement_verification':True})
summary={'scope':'Historical-source reconstruction candidate; distinct from original B13 adhoc artifact','built':True,'signed':True,'configuration_result':'configured: 3AA3QL69MQ, protocol 1','artifacts':artifacts,'unsigned_main_comparison':unsigned,'client_changed_paths':changed,'client_all_other_files_equal':True,'original_final_client_manifest_unchanged':True,'original_b13_helper_sha256_unchanged':sha(original_helper),'production_listener_source_unchanged':True,'production_audit_token_source_unchanged':True,'production_per_message_requirement_source_unchanged':True,'production_authorization_source_unchanged':True,'swiftpm_executed':False,'shared_build_modified':False,'system_registration_performed':False,'authorization_right_modified':False,'root_daemon_started':False,'final_production_client_matrix_executed':False,'runtime_identity_acceptance_verified':False,'limitations':['Static code-signing and helper --check-configuration prove configuration only.','The six-row production Mach service matrix remains unexecuted.','The rebuilt candidate is a debug/WMO swiftc reconstruction with historical repository modules and reused external ArchiveKit build input; it is not the original B13 artifact.']}
(out/'candidate-summary.json').write_text(json.dumps(summary,indent=2)+'\n');(out/'signed-client-manifest.json').write_text(json.dumps(manifest(app),indent=2)+'\n')
(out/'System-Launchd.prepared.plist').write_bytes(plistlib.dumps({'Label':'com.vphone.cli.helper','MachServices':{'com.vphone.cli.helper':True},'ProgramArguments':['/Library/PrivilegedHelperTools/com.vphone.cli.helper'],'StandardOutPath':'/private/var/tmp/vphone-b28-t24-system/helper.stdout.log','StandardErrorPath':'/private/var/tmp/vphone-b28-t24-system/helper.stderr.log'}))
rows=[]
for verb in ['verify-bundle','install-bundle']:
 for log in ['none','new','existing']:
  rows.append({'verb':verb,'log_case':log,'execution_status':'prepared_not_executed','expected_exit':'nonzero','expected_stderr':'Installed helper protocol differs from this client. Register the matching signed helper.','expected_new_log':'absent' if log=='new' else None,'expected_existing_log':'sha256, mode, owner, size and mtime unchanged' if log=='existing' else None,'expected_authorization_call':False,'expected_store_operation':False})
(out/'six-row-matrix.prepared.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(summary,indent=2))
