"""Join the actual A/B/rollback commits, three guest starts and preserved marker, preserving the first failed B observation."""
from pathlib import Path
import json,hashlib
E=Path(__file__).resolve().parent
CLI9='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261021-local/VPhone.bundle/Contents/MacOS/vphone-cli'
CLI4='/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
LIBRARY='/private/tmp/vphone-task8-acceptance-vms'
out=E/'kernel-v9-rollback-acceptance-v2.json';output=out.open('x');r={'passed':False,'inputs':{}}
def read(name):
    data=(E/name).read_bytes();r['inputs'][name]=hashlib.sha256(data).hexdigest();return json.loads(data)
def command_matches(wrapper,cli,arguments,offline=False):
    assert wrapper['exit_code']==0
    command=wrapper['command'];assert command.count(cli)==1
    position=command.index(cli)
    prefix=['sudo','-n','env','PYTHONDONTWRITEBYTECODE=1','VPHONE_PYTHON=/Users/qcz3840/github/vphone-cli/.venv/bin/python3'] if offline else []
    assert command[:position]==prefix and command[position:]==[cli]+arguments
try:
    labels=['kernel-v9-plan-a','kernel-v9-plan-b','kernel-v9-rollback-a']
    boot_labels=['kernel-v9-plan-a','kernel-v9-plan-b-resumed','kernel-v9-rollback-a']
    commits=[read(label+'-readback.json') for label in labels];boots=[read(label+'-boot-watch.json') for label in boot_labels]
    for label,boot_label,commit,boot in zip(labels,boot_labels,commits,boots):
        arguments=['vm','rollback-kernel' if label==labels[2] else 'update-kernel','task8-copy','--library-root',LIBRARY]
        if label==labels[2]:arguments+=['--to-transaction',commits[0]['transaction_id']]
        command_matches(read(label+'.json'),CLI9,arguments,offline=True)
        assert commit['passed'] is True and boot['passed'] is True
        command_matches(read(label+'-vm-stop.json'),CLI4,['vm','stop','task8-copy','--library-root',LIBRARY])
        command_matches(read(label+'-vm-launch.json'),CLI4,['vm','launch','task8-copy','--library-root',LIBRARY,'--headless'])
        cleanup=read(boot_label+'-post-boot-cleanup.json');assert cleanup['passed'] is True and cleanup['source_metadata_unchanged'] is True and cleanup['test_file_identities_unchanged'] is True
        assert commit['proof']['version']=='2.6.20261021-local' and commit['proof']['executableSHA256']=='e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76'
        publication_name=label+'-committed-component-receipts.json';publication=read(publication_name)
        assert publication['transactionID']==commit['transaction_id'] and publication['installed']==commit['receipt'] and boot['expected']['receipt_sha256']==r['inputs'][publication_name]
        assert read(boot_label+'-boot-expectations.json')==boot['expected']
        assert boot['expected']['binding']==dict(commit['binding'],bundle='2.6.20261016-local')
        actual=boot['actual_vm_command'];assert actual.startswith('/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm ') and '--config /private/tmp/vphone-task8-acceptance-vms/task8-copy/config.plist ' in actual
    first_b=read('kernel-v9-plan-b-boot-watch.json')
    assert first_b['passed'] is False and first_b['expected']==boots[1]['expected']
    original_expectation_name='kernel-v9-plan-b-boot-expectations.json'
    read(original_expectation_name)
    assert r['inputs'][original_expectation_name]==r['inputs']['kernel-v9-plan-b-resumed-boot-expectations.json']==first_b['expectations_sha256']
    resume=read('kernel-v9-plan-b-amfi-resume-check.json')
    assert resume['passed'] is True and resume['pid']==95240 and resume['signals_sent']==[{'pid':95240,'signal':'SIGCONT'}]
    for field,value in {'pid':95240,'ppid':1,'uid':0,'path':'/usr/libexec/amfid','start_seconds':1791948408,'start_microseconds':609174}.items():
        assert resume['before'][field]==resume['after'][field]==value
    assert resume['before']['bsd_state']==4 and resume['before']['xstatus']==17 and resume['after']['bsd_state']==2
    assert resume['before']['flags']&2==0 and resume['after']['flags']&2==0
    r['boot_label_mapping']=dict(zip(labels,boot_labels))
    r['first_b_observation_preserved']=True
    r['same_amfid_sigcont_restore_verified']=True
    a,b,rollback=commits
    assert len({x['transaction_id'] for x in commits})==3 and len({x['target']['instance_id'] for x in boots})==3
    assert a['journal_version']==b['journal_version']==3 and rollback['journal_version']==4
    assert a['kernel']['payload_sha256']!=b['kernel']['payload_sha256'] and rollback['kernel']['payload_sha256']==a['kernel']['payload_sha256']
    assert rollback['kernel']['im4p_sha256']==a['kernel']['im4p_sha256'] and rollback['kernel']['img4_sha256']==a['kernel']['img4_sha256']
    assert len({x['kernel']['container_envelope_sha256'] for x in commits})==1 and all(x['kernel']['im4m_im4r_preserved'] is True and x['kernel']['ordered_reconstruction_equals_actual_payload'] is True for x in commits)
    pair=read('kernel-rollback/actual-plan-pair-dsc-v2.json');assert pair['payloadsDiffer'] is True
    known={x['forceExcGuard']:x for x in pair['plans']}
    assert all(known[force]['dsc']=='passed' and commit['kernel']['payload_sha256']==known[force]['payloadSHA256'] and commit['kernel']['im4p_sha256']==known[force]['im4pSHA256'] and commit['receipt']['planSHA256']==known[force]['planSHA256'] for force,commit in [(False,a),(True,b),(False,rollback)])
    selection=rollback['rollback_selection'];assert selection['targetTransactionID']==a['transaction_id']==rollback['proof']['targetTransactionID']
    assert rollback['receipt']['planSHA256']==a['receipt']['planSHA256'] and rollback['receipt']['desiredSHA256']==a['receipt']['desiredSHA256'] and b['receipt']['desiredSHA256']!=a['receipt']['desiredSHA256']
    before=read('kernel-v9-rollback-a-before.json');assert before['desired_sha256']==b['receipt']['desiredSHA256']==selection['liveDesiredSHA256']
    assert before['files']['Disk.img']['sha256']!=b['files']['Disk.img']['sha256']
    created=read('kernel-v9-plan-b-resumed-marker-create.json');restored=read('kernel-v9-rollback-a-marker-read.json')
    assert created['passed'] is True and restored['passed'] is True and created['marker']==restored['marker']
    assert created['expected']==boots[1]['expected'] and restored['expected']==boots[2]['expected']
    assert boots[2]['expected']['desired_sha256']==b['receipt']['desiredSHA256']
    assert created['target']==boots[1]['target'] and restored['target']==boots[2]['target'] and created['target']['instance_id']!=restored['target']['instance_id']
    assert created['downloaded_sha256']==restored['downloaded_sha256']==created['marker']['content_sha256']
    r.update(transaction_ids=[x['transaction_id'] for x in commits],boot_targets=[x['target'] for x in boots],payloads=[x['kernel']['payload_sha256'] for x in commits],rollback_target=a['transaction_id'],live_desired_after_rollback=b['receipt']['desiredSHA256'],installed_desired_after_rollback=a['receipt']['desiredSHA256'],marker_path=created['marker']['path'],marker_sha256=created['downloaded_sha256'],scope='Actual distinct-payload same-producer A/B commits and explicit rollback A, three V4 guest starts, preserved unique B guest marker; does not establish every patch runtime behavior or all filesystem equality',passed=True)
except BaseException as error:r['error']=repr(error);raise
finally:
    output.write(json.dumps(r,indent=2)+'\n');output.close();print(json.dumps({k:v for k,v in r.items() if k!='inputs'}))
    if not r['passed']:raise RuntimeError('Joined committed kernel rollback acceptance failed')
