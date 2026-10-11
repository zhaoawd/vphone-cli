"""离线复核 B38 的构建、两次冷启动及运行断言；不启动 VM。"""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
CODE = HERE.parents[4]

def reject_constant(value):
    raise ValueError('Non-standard JSON constant: ' + value)

def read(name):
    return json.loads((HERE / name).read_text(), parse_constant=reject_constant)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

build = read('default-artifact.json')
api = build['api_sha256']
for item in build['inputs']:
    assert digest(CODE / item['path']) == item['sha256'], item['path']
pins = json.loads((CODE / 'dependencies/daemon-api-pins.json').read_text())['pins']
lock = json.loads((CODE / 'sources/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
assert pins == lock == read('api-candidate-manifest.json')['pins']
assert len(pins) == 7
assert read('api-candidate-manifest.json')['files_sha256']['vphoned'] == api
assert read('default-cohort.json')['api']['files_sha256']['vphoned'] == api
assert read('guest-build-result.json')['exit'] == 0
assert read('deployment.json')['api_sha256'] == api and read('deployment.json')['published']
assert read('deployment.json')['classic_and_environment_before'] == read('deployment.json')['classic_and_environment_after']
classic = None
for name in ['automatic-bootstrap.json', 'second-cold-bootstrap.json']:
    cold = read(name); h = cold['api_health']
    assert cold['automatic_loading_verified'] and cold['classic_roundtrip']['ok']
    assert cold['ssh_banner'].startswith('SSH-2.0-OpenSSH_')
    assert all(s['loaded'] for s in cold['services'].values())
    assert h['binary_hash'] == api and h['bootstrap_startup_enabled'] is True
    assert h['cache_path'] == '/var/root/Library/Caches/vphoned-api'
    assert h['camera_publisher_enabled'] is False and 'camera' not in h['capabilities']
    assert h['source_overlay'].endswith('bc214662ea41c281c3baf3d35805c59fdebaa307ff6163bbce61a4fe6cb46c55')
    assert cold['cache_vphoned-api']['http_status'] == 400
    current = cold['cache_vphoned']['sha256']
    if classic is not None: assert current == classic
    classic = current
matrix = read('runtime-matrix.json')
assert matrix['complete'] and matrix['fd_before']['fds'] == matrix['fd_after']['fds'] == 13
assert matrix['health_before']['instance_id'] == matrix['health_after']['instance_id']
assert len(matrix['concurrent_service_queries']) == 40
assert all(r['http_status'] == 200 for r in matrix['concurrent_service_queries'])
assert sum(b['screenshots'] for b in matrix['memory_batches']) == 60
assert matrix['settled_growth_bytes'] < 60 * 1024**2
samples = [matrix['memory_baseline'], *[b['settled'] for b in matrix['memory_batches']], *matrix['memory_final_samples']]
assert len({(r['pid'], r['start_time']) for r in samples}) == 1
assert matrix['memory_batches'][2]['settled']['footprint_bytes'] <= matrix['memory_batches'][1]['settled']['footprint_bytes']
for row in matrix['rotation_matrix']:
    requested = row['requested']
    assert row['actual']['degrees'] == (0 if requested == 180 else requested)
    assert row['change']['http_status'] == (400 if requested == 180 else 200)
    assert digest(HERE / row['image']) == row['screenshot']['jpeg_sha256']
checks = matrix['checks']
for value in ['NaN', 'Infinity']:
    assert any(r['method'] == 'location.set' and r['params'].get('latitude') == {'nonfinite_number': value} and r['http_status'] == 400 for r in checks)
assert any(r['method'] == 'files.read' and r['reply'].get('result', {}).get('encoding') == 'base64' for r in checks)
service = read('roothide-service.json')
assert service['complete'] and service['final_status']['reply']['result']['loaded'] is False
assert json.loads(service['fixture_signal_state']['content'])['term_ignored_before'] == 1
update = read('cache-update.json')
assert update['complete'] and update['classic_before'] == update['classic_after'] == classic
assert update['health_before']['instance_id'] != update['health_after']['instance_id']
assert update['health_before']['binary_hash'] == update['health_after']['binary_hash'] == api
assert len(update['processes_after']['processes']) == 2
regression = read('regression-result.json')
assert regression['success'] and regression['tests'] == 106 and not regression['skips']
assert '124 checks, 0 failures' in (HERE / 'component-host-tests.txt').read_text()
exits = [read('first-exit.json'), read('second-exit.json')]
assert all(r['exit'] == 0 and r['minimum_free_bytes'] >= 5 * 1024**3 for r in exits)
restored = read('source-restoration.json')
assert restored['guest_roundtrip_verified'] and restored['health_snapshot']['state'] == 'healthy'
assert read('final-readback.json')['research_images_attached'] is False
assert read('classic-compatibility.json')['source_diff']['stdout'] == ''
record = {'accepted': True, 'task': 'T08', 'api_sha256': api, 'pins': 7,
          'source_inputs': len(build['inputs']), 'regression_tests': 106, 'skips': 0,
          'repeated_screenshots': 60, 'worker_fds': [13, 13],
          'settled_growth_bytes': matrix['settled_growth_bytes'],
          'cold_starts': 2, 'source_restored_healthy': True,
          'minimum_runtime_free_bytes': min(r['minimum_free_bytes'] for r in exits),
          'scope': 'fixed API dependency contract; classic control/camera plus independent default API; full modern environment/camera migration excluded'}
(HERE / 'acceptance.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
