import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("stage1", Path(__file__).with_name("accept_stage1.py"))
stage1 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage1)


class Stage1AcceptanceTests(unittest.TestCase):
    def test_other_build_pair_is_refused(self):
        good = {"ios": {"build": "24A446"}, "cloudOS": {"build": "23E5207q"}}
        stage1.check_firmware(good)
        for metadata in ({}, {**good, "ios": {"build": "23A341"}},
                         {**good, "cloudOS": {"build": "23B85"}}):
            with self.assertRaisesRegex(RuntimeError, "build pair"):
                stage1.check_firmware(metadata)

    def test_power_off_cannot_pass_as_graceful_shutdown(self):
        good = "[vphone] Asking the guest to shut down\n[vphone] Guest stopped"
        stage1.check_shutdown(good, "baseline: stopped")
        for boot, stop in ((good + "\nturning it off", ""), (good, "force-killing 123"), ("", "")):
            with self.assertRaises(RuntimeError):
                stage1.check_shutdown(boot, stop)

    def test_probe_rejects_writes_before_opening_socket(self):
        with (patch.object(stage1.socket, "socket", side_effect=AssertionError("unexpected socket")),
              self.assertRaises(ValueError)):
            stage1.request(Path("/unused"), {"t": "tap", "x": 1, "y": 1})

    def test_truncated_reply_is_refused(self):
        with patch.object(stage1.socket, "socket") as factory:
            channel = factory.return_value.__enter__.return_value
            channel.recv.side_effect = [b'{"ok":true}', b'']
            with self.assertRaisesRegex(ValueError, "incomplete"):
                stage1.request(Path("/unused"), {"t": "ping", "screen": False})

    def test_fragmented_response(self):
        with patch.object(stage1.socket, "socket") as factory:
            channel = factory.return_value.__enter__.return_value
            channel.recv.side_effect = [b'{"ok":', b'true}\n']
            self.assertEqual(stage1.request(Path("/unused"), {"t": "ping", "screen": False}), {"ok": True})

    def test_fragment_stream_cannot_extend_total_deadline(self):
        with (patch.object(stage1.socket, "socket") as factory,
              patch.object(stage1.time, "monotonic", side_effect=[0, 1, 4])):
            channel = factory.return_value.__enter__.return_value
            channel.recv.return_value = b'{"ok":'
            with self.assertRaisesRegex(TimeoutError, "deadline"):
                stage1.request(Path("/unused"), {"t": "ping", "screen": False})


if __name__ == "__main__":
    unittest.main()
