import pathlib,shutil,hashlib,json,subprocess
repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');debug=repo/'.build/arm64-apple-macosx/debug';dest=out/'stable';dest.mkdir(exist_ok=False)
manifest=[]
def cp(src,dst):
 dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst);manifest.append({'source':str(src),'copy':str(dst),'sha256':hashlib.file_digest(open(dst,'rb'),'sha256').hexdigest()})
objects=[]
for l in (debug/'vphone-helper.product/Objects.LinkFileList').read_text().splitlines():
 p=pathlib.Path(l)
 if p.parent.name=='VPhoneHelperEntry.build':continue
 dst=dest/'debug'/p.relative_to(debug);cp(p,dst);objects.append(str(dst))
mods=['ArchiveKit','VPhoneArchiveKit','VPhoneBundleStore','VPhoneCore','VPhoneHelperKit']
for mod in mods:
 for p in (debug/'Modules').glob(mod+'.*'):cp(p,dest/'debug/Modules'/p.name)
shutil.copytree(debug/'libarchive.framework',dest/'debug/libarchive.framework',symlinks=False)
slice=repo/'.build/artifacts/libarchive.xcframework/libarchive/libarchive.xcframework/macos-arm64_x86_64';shutil.copytree(slice,dest/'archive-slice',symlinks=False)
(out/'stable-input-manifest.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'files':manifest,'objects':len(objects),'modules':mods},indent=2)+'\n')
(dest/'objects.list').write_text('\n'.join(objects)+'\n')
cp(repo/'.build/debug.yaml',dest/'debug-original.yaml')
print('snapshot complete',len(objects),'objects',len(manifest),'files; no remaining build input reads required')
