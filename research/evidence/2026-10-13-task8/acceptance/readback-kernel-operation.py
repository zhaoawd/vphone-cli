"""Independent stopped-VM readback after a successful official update or rollback."""
from pathlib import Path
import hashlib,json,fcntl,os,plistlib,stat,subprocess,tempfile,sys,re,base64,importlib.util,uuid
import pyimg4
E=Path(__file__).resolve().parent
VM=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1])
label=sys.argv[1];out=E/(label+'-readback.json');output=out.open('x')
expected_path=E/(label+'-operation-expectations.json');expected_raw=expected_path.read_bytes();expected=json.loads(expected_raw)
before=json.loads((E/(label+'-before.json')).read_text());assert before['passed'] is True and before['vm']==str(VM)
assert set(before['files'])=={'Disk.img','nvram.bin','SEPStorage','config.plist','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin'}
assert expected['operation'] in ('update','rollback') and re.fullmatch(r'[0-9a-f]{64}',expected['executableSHA256'])
spec=importlib.util.spec_from_file_location('task8_container_der',E/'container-format/compare-containers.py')
der=importlib.util.module_from_spec(spec);spec.loader.exec_module(der)
def sha(path):
    f=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        s=os.fstat(f);assert stat.S_ISREG(s.st_mode);h=hashlib.sha256()
        with os.fdopen(f,'rb',closefd=False) as stream:
            while b:=stream.read(16<<20):h.update(b)
        t=os.fstat(f);named=path.lstat()
        assert all(getattr(s,k)==getattr(t,k)==getattr(named,k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns'))
        return h.hexdigest()
    finally:os.close(f)
def bytes_sha(b):return hashlib.sha256(b).hexdigest()
commands=[]
def run(args):
    p=subprocess.run(args,capture_output=True);commands.append({'command':args,'exit_code':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode();return p.stdout
def attachments(image):
    return [i for i in plistlib.loads(run(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if os.path.realpath(i.get('image-path',''))==str(image)]
def task8_attachments():
    return [i for i in plistlib.loads(run(['/usr/bin/hdiutil','info','-plist'])).get('images',[]) if 'vphone-task8-acceptance-vms' in i.get('image-path','')]
def fields(data):
    top=der.tlv(data);assert top['tag']=='30' and top['end']==len(data)
    return der.children(data,top)
def export_kernel(image):
    device=None;base=Path(tempfile.mkdtemp(prefix='task8-kernel-readback-',dir='/private/tmp'))
    assert not attachments(image)
    try:
        attached=plistlib.loads(run(['/usr/bin/hdiutil','attach','-readonly','-nomount','-nobrowse','-plist',str(image)]))
        disks=[i['dev-entry'] for i in attached['system-entities'] if i.get('content-hint')=='GUID_partition_scheme'];assert len(disks)==1;device=disks[0]
        containers=plistlib.loads(run(['/usr/sbin/diskutil','apfs','list','-plist']))['Containers']
        matching=[c for c in containers if [p['DeviceIdentifier'] for p in c['PhysicalStores']]==[device.removeprefix('/dev/')+'s1']];assert len(matching)==1
        volumes=[v for v in matching[0]['Volumes'] if v.get('Name','').lower()=='preboot'];assert len(volumes)==1
        volume='/dev/'+volumes[0]['DeviceIdentifier'];mount=base/'preboot';mount.mkdir()
        run(['/sbin/mount_apfs','-o','rdonly',volume,str(mount)])
        info=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]))
        assert info['WritableVolume'] is False and info['MountPoint']==str(mount) and info['VolumeUUID']==volumes[0]['APFSVolumeUUID']
        active=attachments(image);assert len(active)==1 and device in [i['dev-entry'] for i in active[0]['system-entities']]
        identity=(mount.lstat().st_dev,mount.lstat().st_ino);targets=[]
        def walk_error(error):raise error
        for root,dirs,names in os.walk(mount,followlinks=False,onerror=walk_error):
            assert not any(n.lower() in ('kernelcache','kernelcache.research.vphone600') for n in dirs)
            for name in names:
                if name.lower() in ('kernelcache','kernelcache.research.vphone600'):targets.append(Path(root)/name)
        assert len(targets)==1;path=targets[0];s=path.lstat();assert stat.S_ISREG(s.st_mode) and s.st_nlink==1
        data=der.read_regular(path)
        after=plistlib.loads(run(['/usr/sbin/diskutil','info','-plist',volume]))
        assert after['WritableVolume'] is False and after['MountPoint']==str(mount) and after['VolumeUUID']==info['VolumeUUID'] and identity==(mount.lstat().st_dev,mount.lstat().st_ino)
        return data,{'relative_path':str(path.relative_to(mount)),'readonly':True,'volume_info':info}
    finally:
        if device is None:
            active=attachments(image)
            if active:
                assert len(active)==1
                disks=[i['dev-entry'] for i in active[0]['system-entities'] if i.get('content-hint')=='GUID_partition_scheme'];assert len(disks)==1;device=disks[0]
        if device:run(['/usr/bin/hdiutil','detach',device])
        assert not attachments(image)
        for path in base.iterdir():path.rmdir()
        base.rmdir()
fd=os.open(VM,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
r={'passed':False,'label':label,'expected':expected,'expectations_sha256':bytes_sha(expected_raw),'commands':commands,'dsc_scope':'Official production commit validation only; this script does not independently validate DSC'}
try:
    assert not (VM/'.firmware-transaction').exists() and not (VM/'.firmware-desired-pending.json').exists() and not task8_attachments()
    publication_bytes=der.read_regular(VM/'.firmware-component-receipts.json');publication=json.loads(publication_bytes);tx=publication['transactionID']
    assert str(uuid.UUID(tx))==tx
    archive=VM/'.firmware-history'/tx;assert archive.is_dir() and not archive.is_symlink()
    raw={name:der.read_regular(archive/name) for name in ('journal.json','installed-component-proof.json','component-receipts.json','report.json')}
    for name,data in raw.items():
        with (E/(label+'-committed-'+name)).open('xb') as f:f.write(data)
    journal=json.loads(raw['journal.json']);proof=json.loads(raw['installed-component-proof.json']);report=json.loads(raw['report.json']);receipt=publication['installed'];kd=journal['kernelDisk']
    assert publication['schemaVersion']==receipt['schemaVersion']==proof['schemaVersion']==before['desired']['schemaVersion']==1
    binding_bytes=der.read_regular(VM/'launchpad.json');binding=json.loads(binding_bytes)
    r.update(transaction_id=tx,binding=binding,journal_version=journal['version'],proof=proof,receipt=receipt)
    assert journal['id']==tx and journal['kernelOnly'] is True and journal['phase']=='committed'
    assert journal['version']==(4 if expected['operation']=='rollback' else 3)
    assert kd['direction']=='forward' and kd['pending'] is False and kd['cursor']==len(kd['offsets'])
    assert journal['plan']==expected['plan'] and receipt['planSHA256']==expected['planSHA256'] and receipt['desiredSHA256']==expected['desiredSHA256']
    assert journal['options']['desiredSHA256']==expected['desiredSHA256'] and receipt['generationID']==before['desired']['generationID']==journal['options']['generationID']
    assert binding==dict(before['binding'],kernel=expected['version'])
    assert publication['originLayer']=='kernel' and publication['records']==[] and receipt['scope']=='installedComponent' and receipt['state']=='committed' and receipt['component']=='kernelcache'
    assert raw['component-receipts.json']==publication_bytes and bytes_sha(publication_bytes)==journal['componentReceiptsSHA256']
    assert bytes_sha(raw['installed-component-proof.json'])==publication['originProofSHA256'] and bytes_sha(raw['report.json'])==journal['reportSHA256']
    assert proof['producer']=='current-bundle-kernel-update' and proof['rollbackProtocol']=='vphone.kernel-rollback.v1' and proof['version']==expected['version'] and proof['executableSHA256']==expected['executableSHA256'] and proof['transactionID']==tx
    assert report['variant']==journal['plan']['variant'] and report['gates']==journal['plan']['gates'] and report['ablation']==[]
    records=[item for component in report['components'] for item in component.get('records',[])]
    assert [effect['record'] for effect in receipt['effects']]==records and all(effect['outputPath']=='Disk.img' for effect in receipt['effects'])
    selected={entry['id'] for entry in expected['plan']['selected']};assert all(effect['declarationID'] in selected for effect in receipt['effects'])
    assert sha(VM/'.firmware-desired-plan.json')==before['desired_sha256']
    assert sha(VM/'launchpad.json')==bytes_sha(binding_bytes)
    metadata={item['name']:item for item in journal['metadata']};assert len(metadata)==len(journal['metadata']) and set(metadata)=={'.firmware-component-receipts.json','launchpad.json'}
    for name,key,current in [('.firmware-component-receipts.json','receipt',bytes_sha(publication_bytes)),('launchpad.json','binding',bytes_sha(binding_bytes))]:
        assert metadata[name]['original']==before[key+'_sha256'] and metadata[name]['output']==current
    if expected['operation']=='rollback':
        selection=journal['rollbackSelection'];r['rollback_selection']=selection
        assert selection['targetTransactionID']==expected['targetTransactionID']==proof['targetTransactionID']
        assert selection['targetDesired']['plan']==expected['plan'] and selection['targetDesired']['planSHA256']==expected['planSHA256']
        assert selection['liveDesiredSHA256']==before['desired_sha256']==proof['liveDesiredSHA256']
        assert selection['bindingSHA256']==before['binding_sha256']==proof['bindingSHA256']
        assert proof['operation']=='kernel-rollback' and proof['targetDesiredSHA256']==expected['desiredSHA256'] and selection['targetEvidenceSHA256']==proof['targetEvidenceSHA256']
        assert proof['payloadSHA256']==selection['targetPayloadSHA256']==expected['targetPayloadSHA256']
        assert proof['im4pSHA256']==selection['targetIM4PSHA256']==expected['targetIM4PSHA256']
    else:assert 'rollbackSelection' not in journal and before['desired_sha256']==expected['desiredSHA256']
    files={}
    for name,old in before['files'].items():
        path=VM/name;s=path.lstat();assert stat.S_ISREG(s.st_mode)
        digest=sha(path);after=path.lstat();assert (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)==(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)
        assert s.st_dev==old['metadata']['st_dev'] and s.st_ino==old['metadata']['st_ino'] and s.st_size==old['metadata']['st_size']
        files[name]={'sha256':digest,'inode':s.st_ino,'identity_unchanged':True,'content_unchanged':digest==old['sha256']}
        if name!='Disk.img':assert files[name]['content_unchanged']
    r['files']=files
    assert kd['originalSHA256']==before['files']['Disk.img']['sha256']
    assert files['Disk.img']['sha256']==kd['candidateSHA256']==proof['imageSHA256']
    assert receipt['outputs']==[{'path':'Disk.img','sha256':files['Disk.img']['sha256']}]
    data,info=export_kernel(VM/'Disk.img');parts=fields(data);assert der.value(data,parts[0])==b'IMG4' and parts[2]['tag']=='a0'
    im4p=der.raw(data,parts[1]);artifact=der.read_regular(archive/'installed-kernel.im4p')
    assert im4p==artifact and bytes_sha(im4p)==proof['im4pSHA256']
    decoded=pyimg4.IMG4(data).im4p.payload
    if decoded.compression!=pyimg4.Compression.NONE:decoded.decompress()
    payload=decoded.data;assert bytes_sha(payload)==proof['payloadSHA256']
    source=der.read_regular(Path('/private/tmp/task8-pristine-kernel.im4p'));assert bytes_sha(source)==proof['inputSHA256']
    pristine=pyimg4.IM4P(source).payload
    if pristine.compression!=pyimg4.Compression.NONE:pristine.decompress()
    rebuilt=bytearray(pristine.data)
    for record in records:
        offset=record['fileOffset'];original=base64.b64decode(record['originalBytes'],validate=True);patched=base64.b64decode(record['patchedBytes'],validate=True)
        assert type(offset) is int and offset>=0 and len(original)==len(patched)>0 and offset+len(original)<=len(rebuilt)
        assert rebuilt[offset:offset+len(original)]==original
        rebuilt[offset:offset+len(original)]=patched
    assert bytes(rebuilt)==payload
    baseline=der.read_regular(Path('/private/tmp/task8-container-baseline.img4'));assert bytes_sha(baseline)=='5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a'
    original_parts=fields(baseline);assert [der.raw(data,x) for x in parts[2:]]==[der.raw(baseline,x) for x in original_parts[2:]]
    envelope=b''.join(der.raw(data,x) for x in parts[:1]+parts[2:]);assert bytes_sha(envelope)==proof['containerEnvelopeSHA256']
    im4p_parts=fields(im4p);source_parts=fields(source)
    assert der.raw(im4p,im4p_parts[2])==der.raw(source,source_parts[2])
    payp=[der.raw(im4p,x) for x in im4p_parts[4:] if x['tag']=='a0'];original_payp=[der.raw(source,x) for x in source_parts[4:] if x['tag']=='a0'];assert payp==original_payp and len(payp)==1
    r['kernel']={**info,'img4_sha256':bytes_sha(data),'im4p_sha256':bytes_sha(im4p),'payload_sha256':bytes_sha(payload),'description':der.value(im4p,im4p_parts[2]).decode(),'payp_sha256':bytes_sha(payp[0]),'im4m_sha256':bytes_sha(der.raw(data,parts[2])),'container_envelope_sha256':bytes_sha(envelope),'im4m_im4r_preserved':True,'ordered_reconstruction_equals_actual_payload':True}
    r['disk_sha256_after_readonly']=sha(VM/'Disk.img');assert r['disk_sha256_after_readonly']==files['Disk.img']['sha256']
    assert sha(VM/'.firmware-desired-plan.json')==before['desired_sha256'] and expected_path.read_bytes()==expected_raw
    assert sha(VM/'launchpad.json')==bytes_sha(binding_bytes) and sha(VM/'.firmware-component-receipts.json')==bytes_sha(publication_bytes)
    assert all(sha(archive/name)==bytes_sha(data) for name,data in raw.items())
    r['passed']=True
except BaseException as error:r['error']=repr(error);raise
finally:
    try:
        r['remaining_attachments']=task8_attachments();r['pending']=(VM/'.firmware-transaction').exists() or (VM/'.firmware-desired-pending.json').exists()
        if r['remaining_attachments'] or r['pending']:r['passed']=False
    except BaseException as error:r['cleanup_error']=repr(error);r['passed']=False
    os.close(fd);output.write(json.dumps(r,indent=2,default=str)+'\n');output.close();print(json.dumps({k:v for k,v in r.items() if k not in ('commands','receipt')},default=str))
    if not r['passed']:raise RuntimeError('Independent committed kernel readback failed')
