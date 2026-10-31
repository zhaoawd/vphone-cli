"""Cross-language publication/Undo with mocked Store producer qualification."""
import json
import os
from pathlib import Path
import runpy
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]
from patchers import guest_origin
import cfw_disk_txn as txn

vm = Path(sys.argv[1])
context = json.loads(os.environ['VPHONE_FROZEN_CONTEXT'])
version = '2.6.2-local.identityfixture'
mode = os.environ.get('VPHONE_TEST_ORIGIN_IDENTITY_MODE', 'source')
assert mode in ('source', 'invalidation')
(vm / 'launchpad.json').write_text(json.dumps({'bundle': version, 'guestEnvironment': '2.6.1'}))
source = dict(schemaVersion=1, producer='current-verified-core-bundle-cli',
              version=version, executable=context['verifierPath'],
              executableSHA256=context['verifierSHA256'], resourceBase=str(ROOT),
              archiveSHA256='a' * 64, cliCDHash='b' * 40)
if mode == 'source':
    os.environ[guest_origin.ENV] = json.dumps(source)
native_stage = txn.stage
first = True


def stage(args):
    global first
    qualified = guest_origin.ENV in os.environ
    if first and mode == 'invalidation':
        args.invalidate_guest_origin = True
    native_stage(args)
    if qualified:
        assert (args.work / guest_origin.SOURCE).is_file()
        os.environ.pop(guest_origin.ENV)
    if first and mode == 'invalidation':
        assert (args.work / guest_origin.INVALIDATION).is_file()
    first = False


with patch.object(guest_origin, 'live_source', return_value=source), \
     patch.object(guest_origin, 'verify_source', side_effect=lambda value, **kwargs: value), \
     patch.object(guest_origin, 'OWNER', os.geteuid()), \
     patch.object(txn, 'stage', side_effect=stage):
    runpy.run_path(str(ROOT / 'tests/cfw_file_identity_bridge_fixture.py'), run_name='__main__')
