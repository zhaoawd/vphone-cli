import contextlib
import hashlib
import json
from pathlib import Path
import socket
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import start_t32_observation_window as starter

class RuntimeSocketPreflightTests(unittest.TestCase):
    def test_oversized_socket_refuses_before_root_window_start(self):
        with tempfile.TemporaryDirectory() as raw:
            work=Path(raw);vm=work/('v'*120);vm.mkdir();(vm/'Disk.img').write_bytes(b'fixture')
            backup=b'{}';(work/'runtime-backup.json').write_bytes(backup)
            plan=dict(vm=str(vm),frozenTools={},backupManifestSHA256=hashlib.sha256(backup).hexdigest(),
                      expectedCurrentImageSHA256=hashlib.sha256(b'fixture').hexdigest())
            data=json.dumps(plan).encode();digest=hashlib.sha256(data).hexdigest()
            (work/'runtime-plan.json').write_bytes(data)
            (work/'runtime-approval.json').write_text(json.dumps(dict(approved=True,planSHA256=digest)))
            modules={'cfw_verify_effects':types.SimpleNamespace(locked_vm=lambda vm:contextlib.nullcontext()),
                     'cfw_disk_txn':types.SimpleNamespace(require_unheld=lambda *args:None)}
            with patch.object(starter,'WORK',work), patch.object(starter.os,'geteuid',return_value=0), \
                 patch.object(sys,'argv',['starter','--execute-approved-runtime-plan',digest]), \
                 patch.dict(sys.modules,modules), patch.object(starter.subprocess,'run',side_effect=AssertionError('Helper must not start')) as run:
                with self.assertRaisesRegex(ValueError,'socket path'):
                    starter.main()
                run.assert_not_called()
            self.assertFalse((work/'root-window-start.log').exists())

    def test_capacity_counts_utf8_and_nul(self):
        from t32_runtime_preflight import validate_control_socket
        for name in ('a'*102,'界'*34):
            self.assertEqual(validate_control_socket('/',socket_name=name)['bytesIncludingNul'],104)
        for name in ('a'*103,'界'*34+'a','bad\0path'):
            with self.subTest(name=name),self.assertRaises(ValueError):validate_control_socket('/',socket_name=name)

    @unittest.skipUnless(sys.platform=='darwin','macOS Unix socket ABI')
    def test_actual_darwin_bind_rejects_failed_vm_path(self):
        path='/Users/kolar/github/vphone-cli/.build/t32-t33-completion-20261023/fresh-library/t32-t33-file-acceptance-20261023/vphone.sock'
        with socket.socket(socket.AF_UNIX) as s:
            with self.assertRaisesRegex(OSError,'too long'):s.bind(path)

if __name__=='__main__':unittest.main()
