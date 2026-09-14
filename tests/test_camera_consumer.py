"""Compile the production shm reader with allocator/copy fault injection."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CameraConsumerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="camera-consumer-")
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        source = (ROOT / "scripts/vcamcaptured/libvcamcaptured.m").read_text()
        # Compile exact production declarations and function; do not duplicate its logic.
        layout = source[source.index("#define VCC_SHM_PATH"):source.index("// Observe shm")]
        latest = re.search(r'typedef struct vcc_latest_frame_s \{.*?\} vcc_latest_frame_t;', source, re.S).group()
        reader = source[source.index("static int vcc_shm_read_latest(void) {"):source.index("static void vcc_start_frame_receiver(void) {")]
        (directory / "camera_consumer_types.h").write_text(layout + latest)
        (directory / "camera_consumer_reader.h").write_text(reader)
        cls.binary = directory / "camera-consumer"
        result = subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc",
                                 "-framework", "Foundation", "-I", str(directory),
                                 str(ROOT / "tests/fixtures/camera_consumer_harness.m"), "-o", str(cls.binary)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def run_case(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_successful_copy_writes_observation(self):
        self.run_case("valid")

    def test_allocation_failure_does_not_write_observation(self):
        self.run_case("allocation")

    def test_torn_copy_is_not_exposed_to_app_or_acknowledged(self):
        self.run_case("torn")
