import sys,subprocess,os,json,hashlib,gzip,time,pathlib
root=pathlib.Path(__file__).resolve().parent
label=sys.argv[1]; cmd=sys.argv[2:]
files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--','sources','tests','Package.swift','Package.resolved']).decode().splitlines()
files+= ['vendor/libcapstone-spm/Sources/Capstone/Instruction.swift', 'scripts/check_bundle.py']
files+= [str(p) for p in pathlib.Path('sources').rglob('FirmwareKernel*.swift')]+[str(p) for p in pathlib.Path('tests').rglob('FirmwareKernel*.swift')]
sha={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in sorted(set(files)) if pathlib.Path(p).is_file()}
env=os.environ.copy()
for k in list(env):
 if k.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_')):env.pop(k)
t=time.time();r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env);raw=r.stdout
(root/(label+'.log')).write_bytes(raw)
with gzip.GzipFile(filename=str(root/(label+'.log.gz')),mode='wb',mtime=0) as f:f.write(raw)
(root/(label+'.json')).write_text(json.dumps({'command':cmd,'exit':r.returncode,'seconds':time.time()-t,'base':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),'sourceSHA256':sha,'logSHA256':hashlib.sha256(raw).hexdigest()},indent=2)+'\n')
print(raw.decode(errors='replace'));sys.exit(r.returncode)
