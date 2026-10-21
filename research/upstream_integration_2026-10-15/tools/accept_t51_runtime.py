"""Repeatable T51 acceptance on fresh APFS clones of the stopped vm-new.
Never mutates the source, deletes fixtures, or changes host security policy.
"""
import argparse,fcntl,hashlib,json,os,plistlib,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t51rt'
LIB=WORK/'lib'
SOURCE=ROOT/'vm-new'
NAMES=['Disk.img','config.plist','SEPStorage','nvram.bin','.vphoned.signed',
       'AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin','udid-prediction.txt']
def write(name,value):
    (WORK/name).write_text(json.dumps(value,indent=2)+'\n')
def signature(p):
    s=p.stat();return dict(device=s.st_dev,inode=s.st_ino,size=s.st_size,mtimeNS=s.st_mtime_ns,ctimeNS=s.st_ctime_ns,allocated=s.st_blocks*512)
def digest(p):
    before=signature(p)
    print('hash '+str(p),flush=True)
    with p.open('rb') as f: result=hashlib.file_digest(f,'sha256').hexdigest()
    assert signature(p)==before, 'file changed during digest'
    return result
def files(vm):
    return {n:digest(vm/n) for n in NAMES if (vm/n).is_file()}
def run(argv,name,expected=0):
    print('run '+name,flush=True)
    start=time.time()
    with (WORK/(name+'.log')).open('w') as out:
        child=subprocess.run(list(map(str,argv)),stdout=out,stderr=subprocess.STDOUT,timeout=1800,
                             env=dict(os.environ,VPHONE_ROOT=str(WORK/'user-root'),VPHONE_PYTHON=str(ROOT/'.venv/bin/python3')))
    result=dict(argv=list(map(str,argv)),exitCode=child.returncode,seconds=time.time()-start)
    write(name+'.json',result)
    assert child.returncode==expected, result
    return (WORK/(name+'.log')).read_text()
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('phase',choices=['prepare','rebase','final-source']);parser.add_argument('--cli',type=Path)
    args=parser.parse_args();WORK.mkdir(exist_ok=True);LIB.mkdir(exist_ok=True)
    if args.phase=='prepare':
        assert not (LIB/'base').exists() and not (LIB/'target').exists(), 'fresh names required'
        fd=os.open(SOURCE,os.O_RDONLY)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            for n in ('Disk.img','SEPStorage','nvram.bin'):
                holders=subprocess.run(['/usr/sbin/lsof','-nP','-t','--',str(SOURCE/n)],capture_output=True,text=True)
                assert holders.returncode==1 and not holders.stdout and not holders.stderr, holders
            images=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
            assert not any(Path(i.get('image-path','')).resolve()==SOURCE/'Disk.img' for i in images.get('images',[])), 'source attached'
            original=files(SOURCE);sourceSignature={n:signature(SOURCE/n) for n in original}
            write('source-before.json',dict(files=original,signatures=sourceSignature))
            for name in ('base','target'):
                subprocess.run(['/bin/cp','-cR',str(SOURCE),str(LIB/name)],check=True)
                assert (LIB/name/'Disk.img').stat().st_ino!=(SOURCE/'Disk.img').stat().st_ino
            # Rewriting identical bytes allocates private blocks without changing guest content.
            with (LIB/'target/Disk.img').open('r+b',buffering=0) as target:
                data=target.read(64<<20);target.seek(0);target.write(data);target.flush();os.fsync(target.fileno());fcntl.fcntl(target.fileno(),51)
            assert files(LIB/'target')==original, 'fresh target bytes differ'
            assert {n:signature(SOURCE/n) for n in original}==sourceSignature, 'source changed'
            write('prepared.json',dict(state='passed',source=str(SOURCE),sourceFiles=original,sourceSignatures=sourceSignature,
                baseDisk=signature(LIB/'base/Disk.img'),targetDisk=signature(LIB/'target/Disk.img'),identicalPrivateRewriteBytes=64<<20))
        finally:os.close(fd)
    elif args.phase=='rebase':
        assert args.cli and args.cli.is_file()
        record=json.loads((WORK/'prepared.json').read_text());original=record['sourceFiles']
        common=[args.cli,'vm','rebase','target','--onto','base','--library-root',LIB]
        initial=signature(LIB/'target/Disk.img')
        # An unrelated reader must cause a precise refusal, without signalling it.
        with (LIB/'target/Disk.img').open('rb') as holder:
            output=run(common+['--dry-run'],'reader-refusal',expected=1)
            assert 'does not run it' in output and str(os.getpid()) in output, output
            assert signature(LIB/'target/Disk.img')==initial
        output=run(common+['--dry-run'],'dry-run')
        assert 'would be newly shared' in output and signature(LIB/'target/Disk.img')==initial
        output=run(common,'rebase')
        assert 'rebased target onto base' in output
        final=signature(LIB/'target/Disk.img');assert final['inode']!=initial['inode']
        assert files(LIB/'target')==original, 'rebase changed guest persistent bytes'
        assert files(LIB/'base')==original, 'base bytes changed'
        assert not list((LIB/'target').glob('.rebase-*')), 'pending rebase remains'
        history=list((LIB/'target/.disk-rebase-history').glob('*/RebaseJournal.json'))
        assert history, 'published journal missing'
        journals=[json.loads(p.read_text()) for p in history]
        run(common+['--dry-run'],'after-dry-run')
        write('rebase-result.json',dict(state='passed',cliSHA256=digest(args.cli),logicalBytes=final['size'],
            before=initial,after=final,targetPersistentBytesUnchanged=True,basePersistentBytesUnchanged=True,journals=journals,
            physicalExternalVolumeValidated=False,guestBootValidated=False))
    else:
        expected=json.loads((WORK/'source-before.json').read_text())
        fd=os.open(SOURCE,os.O_RDONLY)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            assert files(SOURCE)==expected['files']
            assert {n:signature(SOURCE/n) for n in expected['files']}==expected['signatures']
            write('source-after.json',dict(state='passed',persistentFilesUnchanged=True,signaturesUnchanged=True))
        finally:os.close(fd)
    print('passed '+args.phase,flush=True)
if __name__=='__main__':main()
