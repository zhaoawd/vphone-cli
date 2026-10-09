import hashlib,json,os,pathlib,stat,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
inv=json.loads((OUT/'inventory.json').read_text())
def filehash(p):
 with p.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
checks=[]; mismatches=[]
for label in ['framework','packages','venv_bin']:
 source=P(inv['roots'][label]['path']); dest=ROOT/({'framework':'Frameworks/Python.framework','packages':'site-packages','venv_bin':'unused'}[label])
 entries=json.loads((OUT/(label+'-entries.json')).read_text()); source_checks=0;copy_checks=0
 for entry in entries:
  p=source/entry['path']
  if entry['kind']=='file':
   source_checks+=1
   if not p.is_file() or filehash(p)!=entry['sha256']: mismatches.append({'root':label,'path':entry['path'],'side':'source'})
   if label!='venv_bin':
    copy_checks+=1; q=dest/entry['path']
    if not q.is_file() or filehash(q)!=entry['sha256'] or stat.S_IMODE(q.stat().st_mode)!=int(entry['mode'],8): mismatches.append({'root':label,'path':entry['path'],'side':'copy'})
  elif entry['kind']=='symlink':
   if not p.is_symlink() or os.readlink(p)!=entry['target']: mismatches.append({'root':label,'path':entry['path'],'side':'source-link'})
   if label!='venv_bin':
    q=dest/entry['path']
    if not q.is_symlink() or os.readlink(q)!=entry['target']: mismatches.append({'root':label,'path':entry['path'],'side':'copy-link'})
 checks.append({'root':label,'source_file_hash_checks':source_checks,'copy_file_hash_and_mode_checks':copy_checks})
for p,e in inv['external_native'].items():
 target=ROOT/'lib'/P(e['load_path']).name
 if filehash(P(p))!=e['sha256'] or filehash(target)!=e['sha256']: mismatches.append({'native':p})
lazy=json.loads((OUT/'lazy-native-copy-trial.json').read_text())['added_dylib']
if filehash(P(lazy['source']))!=lazy['sha256'] or filehash(P(lazy['target']))!=lazy['sha256']: mismatches.append({'native':lazy['source']})
entries=[]
for base,dirs,files in os.walk(ROOT,followlinks=False):
 for name in sorted(dirs+files):
  p=P(base)/name; s=p.lstat(); e={'path':str(p.relative_to(ROOT)),'mode':oct(stat.S_IMODE(s.st_mode))}
  if p.is_symlink():e.update(kind='symlink',target=os.readlink(p))
  elif p.is_file():e.update(kind='file',bytes=s.st_size,sha256=filehash(p))
  else:e.update(kind='directory')
  entries.append(e)
entries.sort(key=lambda e:e['path'])
manifest={'schema':'experimental-read-only-copy-inventory-v1','entries':entries,'sha256':hashlib.sha256(json.dumps(entries,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'bytes':sum(e.get('bytes',0) for e in entries)}
(OUT/'runtime-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
extended=json.loads((OUT/'sandbox-env-extended.stdout').read_text().splitlines()[-1]); native_paths=[i for i in extended['images'] if not i.startswith(('/System/','/usr/lib/'))]
stdlib_entries=json.loads((OUT/'framework-entries.json').read_text())
stdlib=[e for e in stdlib_entries if e['path'].startswith('Versions/3.14/lib/python3.14/') and e['kind']=='file']
summary={'checks':checks,'mismatches':mismatches,'runtime_manifest_sha256':manifest['sha256'],'runtime_regular_bytes':manifest['bytes'],'runtime_entries':len(entries),'stdlib_regular_files':len(stdlib),'stdlib_bytes':sum(e['bytes'] for e in stdlib),'package_distribution_count':len(inv['packages']),'native_inventory_count':inv['native_count'],'recursive_linked_homebrew_dylibs':len(inv['external_native']),'lazy_ctypes_homebrew_dylibs':1,'external_native_bytes_including_lazy':inv['external_native_bytes']+lazy['bytes'],'loaded_images_total':len(extended['images']),'loaded_non_system_images':len(native_paths),'loaded_non_system_images_outside_runtime':[i for i in native_paths if not i.startswith(str(ROOT)+'/')],'imported_module_files_total':len(extended['module_files']),'imported_module_files_outside_runtime':{k:v for k,v in extended['module_files'].items() if not v.startswith(str(ROOT)+'/')}}
(OUT/'verification.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2)); assert not mismatches; assert manifest['bytes']<1024**3
