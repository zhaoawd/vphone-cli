"""Verify that cleanup cannot resume a different process or an active debugger."""
import unittest
from t52_amfid_cleanup import resume_action


class AMFIDCleanupTests(unittest.TestCase):
    def test_only_same_paused_amfid_can_be_resumed(self):
        original = dict(pid=123, uid=0, started='Thu Oct 22 23:00:00 2026', executable='/usr/libexec/amfid')
        def action(current, status='Ts', **kwargs):
            return resume_action(original, current, status, helper_stopped=kwargs.get('helper_stopped', True), debugserver_absent=kwargs.get('debugserver_absent', True))
        self.assertEqual(action(original), 'SIGCONT')
        self.assertEqual(action(original, 'S'), 'not_paused')
        self.assertEqual(action(None), 'original_process_exited')
        for key, value in [('pid', 124), ('uid', 501), ('started', 'different'), ('executable', '/tmp/amfid')]:
            with self.subTest(key=key): self.assertEqual(action({**original, key: value}), 'refused_identity_changed')
        self.assertEqual(action(original, helper_stopped=False), 'refused_debugger_or_helper_remains')
        self.assertEqual(action(original, debugserver_absent=False), 'refused_debugger_or_helper_remains')


if __name__ == '__main__': unittest.main()
