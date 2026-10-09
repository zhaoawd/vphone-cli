from pathlib import Path
import shutil,json,hashlib
out=Path('/private/tmp/vphone-b26-t46-helper');dest=out/'evidence';dest.mkdir(exist_ok=False)
(out/'legacy-v1-status.json').write_text(json.dumps({'status':'prepared_not_executed','original_artifact_sha256':'bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4','original_configuration_exit':78,'source_candidate':'dd3c800277605589ae1cb2466a2b33fa33e549d1','build_performed':False,'signature_performed':False,'registration_performed':False,'identity':'Apple Development; Team3AA3QL69MQ; not Developer ID','scope':'Distinct historical-source reconstruction proposal, never the same original adhoc artifact.'},indent=2)+'\n')
allowed={'.json','.md','.swift','.py','.plist','.txt','.stderr','.stdout','.ips','.pem'}
for p in out.iterdir():
 if p.is_file() and p.suffix in allowed:shutil.copy2(p,dest/p.name)
shutil.copytree(out/'legacy-v1-source',dest/'legacy-v1-source')
for p in sorted(out.glob('*.json')):
 try:d=json.loads(p.read_text())
 except:continue
 if isinstance(d,dict) and 'events' in d and 'stdout' in d:
  (dest/(p.stem+'.stdout')).write_text(d['stdout']);(dest/(p.stem+'.stderr')).write_text(d['stderr'])
 if isinstance(d,list) and p.name.startswith(('sign-readback','sign-verification')):
  for i,c in enumerate(d):
   if isinstance(c,dict) and 'argv' in c:
    (dest/(p.stem+f'.command-{i:02d}.stdout')).write_text(c.get('stdout',''));(dest/(p.stem+f'.command-{i:02d}.stderr')).write_text(c.get('stderr',''))
(dest/'archive-policy.md').write_text('''# 归档范围

本目录仅保留源码、脚本、公开签名证据、运行JSON及其中stdout/stderr的原样提取、精确harness崩溃报告、摘要、清理记录与manifest。stable对象库、app、可执行文件和framework二进制仍保留在/tmp原物，没有复制至本目录。stdout/stderr提取来源为同stem JSON中的原始字符串。

源码TransportHarness.swift开头的prepared-only注释保留编译时原文；最终状态由summary.json及实际编译/签名/矩阵证据确定。legacy-v1-source和proposed plist仅prepared_not_executed，未构建、签名或注册。

manifest.json记录本目录除manifest自身之外全部文件的大小与SHA256；其自身摘要保存在/tmp父目录evidence-manifest-verification.json中，并由verify-archive.py独立重算全部条目。
''')
rows=[]
for p in sorted(dest.rglob('*')):
 if p.is_file():rows.append({'path':str(p.relative_to(dest)),'size':p.stat().st_size,'sha256':hashlib.file_digest(open(p,'rb'),'sha256').hexdigest()})
(dest/'manifest.json').write_text(json.dumps({'self_excluded':'manifest.json','files':rows},indent=2)+'\n')
print('archive',dest,'files',len(rows),'bytes',sum(f['size'] for f in rows))
