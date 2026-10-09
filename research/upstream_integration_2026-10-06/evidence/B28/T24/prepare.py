import pathlib,subprocess,hashlib,json,shutil
repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');out=pathlib.Path('/private/tmp/vphone-b28-t24');ref='dd3c800277605589ae1cb2466a2b33fa33e549d1';stable=pathlib.Path('/private/tmp/vphone-b26-t46-helper/stable');files=[]
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',ref,'sources/VPhoneHelperEntry','sources/VPhoneHelperKit','sources/VPhoneArchiveKit','sources/VPhoneBundleStore'],cwd=repo,text=True).splitlines()+['Package.swift','Package.resolved','scripts/build_helper_candidate.sh']
for name in paths:
 p=out/'source'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(subprocess.check_output(['git','show',ref+':'+name],cwd=repo));files.append({'path':name,'sha256':sha(p),'git_blob':subprocess.check_output(['git','rev-parse',ref+':'+name],cwd=repo,text=True).strip()})
for name in ['Legacy-Helper-Info.proposed.plist','Legacy-Helper-Launchd.proposed.plist']:
 shutil.copy2('/private/tmp/vphone-b26-t46-helper/'+name,out/name)
(out/'Modules').mkdir(exist_ok=True);(out/'inputs').mkdir(exist_ok=True)
for p in (stable/'debug/Modules').glob('ArchiveKit.*'):shutil.copy2(p,out/'Modules'/p.name)
shutil.copy2(stable/'debug/ArchiveKit.build/ArchiveKit.swift.o',out/'inputs/ArchiveKit.swift.o')

if not (out/'inputs/archive-slice').exists():
 shutil.copytree(stable/'archive-slice',out/'inputs/archive-slice',symlinks=True)
input_files=[{'path':str(p.relative_to(out)),'sha256':sha(p)} for p in (out/'inputs').rglob('*') if p.is_file() and not p.is_symlink()]+[{'path':str(p.relative_to(out)),'sha256':sha(p)} for p in (out/'Modules').glob('*')]
original=repo/'.build/acceptance/B13/prior-helper-candidate/com.vphone.cli.helper';origsha=sha(original)
manifest={'historical_source_revision':ref,'repository_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'final_source_revision':'b4e80c57','historical_source_files':files,'reused_external_archivekit_inputs':input_files,'external_package_resolved':json.loads((out/'source/Package.resolved').read_text()),'original_adhoc_path':str(original),'original_adhoc_sha256':origsha,'original_adhoc_expected_sha256':'bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4','historical_source_unmodified':True,'scope':'historical-source reconstruction; not original B13 artifact; no SwiftPM build used'}
assert origsha==manifest['original_adhoc_expected_sha256']
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('historical source files',len(files),'external input files',len(input_files),'original',origsha)
