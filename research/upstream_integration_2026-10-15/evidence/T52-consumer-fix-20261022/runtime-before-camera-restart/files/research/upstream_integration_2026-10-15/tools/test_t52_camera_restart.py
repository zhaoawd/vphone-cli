"""Check the exact process identity gate without sending a signal."""
import unittest
from capture_t52_camera_restart import BUNDLE, checked_camera_process


class CameraRestartGateTests(unittest.TestCase):
    def test_accepts_only_the_named_stopped_probe_session(self):
        camera = dict(name='cameracaptured', executable='/usr/libexec/cameracaptured', pid=70, uid=501, start_time=1792683621.488895)
        self.assertIs(checked_camera_process([camera]), camera)
        for key, value in [('pid', 71), ('uid', 0), ('start_time', 1792683622), ('executable', '/tmp/cameracaptured')]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                checked_camera_process([{**camera, key: value}])
        for rows in [[], [camera, camera], [camera, dict(name='T52Acceptance', bundle_id=BUNDLE)]]:
            with self.subTest(rows=rows), self.assertRaises(AssertionError): checked_camera_process(rows)


if __name__ == '__main__': unittest.main()
