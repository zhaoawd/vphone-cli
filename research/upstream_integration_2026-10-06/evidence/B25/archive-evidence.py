from pathlib import Path
import shutil,hashlib,json,subprocess
repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
evidence=repo/'research/upstream_integration_2026-10-06/evidence'
root=evidence/'B25';root.mkdir(exist_ok=True)
(root/'.gitattributes').write_text('* -text\n')
for stem in ('vphone-b25','vphone-b25-t24','vphone-b25-t40','vphone-b25-t46'):
 source=Path('/private/tmp')/stem;dest=root/stem.removeprefix('vphone-b25').strip('-');dest.mkdir(exist_ok=True)
 for path in source.iterdir():
  if path.is_file() and path.suffix in ('.json','.log','.py','.swift','.md','.txt','.c','.sb','.trustcache'):
   shutil.copyfile(path,dest/path.name)
 if stem.endswith('t24'):
  subsource=source/'final-proof'
  if subsource.exists():
   subdest=dest/'final-proof';subdest.mkdir(exist_ok=True)
   for file in subsource.iterdir():
    if file.is_file() and file.suffix in ('.json','.stdout','.stderr','.trustcache'):
     shutil.copyfile(file,subdest/file.name)
 if stem.endswith('t46'):
  for extra in ('scheduling','legacy-fixtures'):
   subsource=source/extra
   if subsource.exists():
    subdest=dest/extra;subdest.mkdir(exist_ok=True)
    for file in subsource.iterdir():
     if file.is_file() and file.suffix in ('.json','.log','.py','.swift','.txt'):
      shutil.copyfile(file,subdest/file.name)
  for mode in ('normal','escaped','final-normal','final-escaped'):
   sub=dest/('ui-'+mode);sub.mkdir(exist_ok=True)
   for path in (source/('ui-'+mode)).glob('*.json'):shutil.copyfile(path,sub/path.name)
   if not (source/('ui-'+mode)/'result.json').exists():continue
   result=json.loads((source/('ui-'+mode)/'result.json').read_text());shutil.copyfile(result['log'],sub/'command.log')
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
files=[]
for path in sorted(root.rglob('*')):
 if path.is_file():
  b=path.read_bytes();files.append({'path':str(path.relative_to(evidence)),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
(evidence/'B25-evidence-manifest.json').write_text(json.dumps({'implementation_head':head,'files':files,'bytes':sum(x['bytes'] for x in files)},indent=2)+'\n')
print(json.dumps({'files':len(files),'bytes':sum(x['bytes'] for x in files),'head':head}))
