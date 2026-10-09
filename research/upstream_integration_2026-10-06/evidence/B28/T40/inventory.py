import hashlib,json,os,pathlib,stat,subprocess,time
P=pathlib.Path
OUT=P('/private/tmp/vphone-b28-t40')
FW=P('/opt/homebrew/Cellar/python@3.14/3.14.4_1/Frameworks/Python.framework')
VENV=P('/Users/qcz3840/github/vphone-cli/..venv.generations/env-9asn3gud')
ROOTS={'framework':FW,'packages':VENV/'lib/python3.14/site-packages','venv_bin':VENV/'bin'}
MAGIC={b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca'}
report={'scope':'Scoped read-only inventory; no site initialization or runtime import','roots':{},'native':{},'external_native':{},'startup_files':[],'packages':[]}
native=[]
for label,root in ROOTS.items():
 entries=[]; total=0; regular=0; links=[]
 for base,dirs,files in os.walk(root,followlinks=False):
  for name in sorted(dirs+files):
   p=P(base)/name; s=p.lstat(); rel=str(p.relative_to(root))
   if stat.S_ISLNK(s.st_mode):
    target=os.readlink(p); resolved=p.resolve(); ent={'path':rel,'kind':'symlink','target':target,'resolved':str(resolved),'external':not resolved.is_relative_to(root)}; links.append(ent)
   elif stat.S_ISREG(s.st_mode):
    total+=s.st_size; regular+=1
    with p.open('rb') as f: magic=f.read(4); f.seek(0); digest=hashlib.file_digest(f,'sha256').hexdigest()
    ent={'path':rel,'kind':'file','bytes':s.st_size,'sha256':digest,'mode':oct(stat.S_IMODE(s.st_mode))}
    if magic in MAGIC: native.append(p)
    if name in ('sitecustomize.py','usercustomize.py') or p.suffix=='.pth': report['startup_files'].append({'root':label,'path':rel,'text':p.read_text(errors='replace') if s.st_size<16384 else 'too-large-to-display'})
    if label=='packages' and name=='METADATA' and p.parent.name.endswith('.dist-info'):
     fields={}
     for line in p.read_text(errors='replace').splitlines():
      if line.startswith(('Name:','Version:')):
       k,v=line.split(':',1); fields[k]=v.strip()
     report['packages'].append(fields)
   else: ent={'path':rel,'kind':'directory' if p.is_dir() else 'other'}
   entries.append(ent)
 entries.sort(key=lambda e:e['path'])
 encoded=json.dumps(entries,sort_keys=True,separators=(',',':')).encode()
 (OUT/(label+'-entries.json')).write_text(json.dumps(entries,indent=2)+'\n')
 report['roots'][label]={'path':str(root),'regular_files':regular,'bytes':total,'entry_count':len(entries),'entry_sha256':hashlib.sha256(encoded).hexdigest(),'symlinks':links}
seen=set(); queue=list(native)
while queue:
 p=queue.pop(0).resolve()
 if str(p) in seen: continue
 seen.add(str(p))
 r=subprocess.run(['/usr/bin/otool','-L',str(p)],capture_output=True,text=True)
 lines=r.stdout.splitlines(); links=[]
 for line in lines[1:]:
  if not line.startswith('\t'): continue
  dep=line.strip().split(' (compatibility version ',1)[0]; links.append(dep)
  if dep.startswith('/opt/homebrew/'):
   d=P(dep)
   if d.is_file():
    real=d.resolve()
    if not any(real.is_relative_to(root) for root in ROOTS.values()):
     if str(real) not in report['external_native']:
      with real.open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
      report['external_native'][str(real)]={'load_path':dep,'bytes':real.stat().st_size,'sha256':digest}
     queue.append(real)
 report['native'][str(p)]={'returncode':r.returncode,'links':links,'stderr':r.stderr}
report['native_count']=len(native)
report['external_native_bytes']=sum(e['bytes'] for e in report['external_native'].values())
report['candidate_copy_bytes']=sum(e['bytes'] for k,e in report['roots'].items() if k!='venv_bin')+report['external_native_bytes']
(OUT/'inventory.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k in ('roots','native_count','external_native','external_native_bytes','candidate_copy_bytes','startup_files')},indent=2))
