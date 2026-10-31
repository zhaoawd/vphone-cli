"""Catch loss of the formally installed probe's data-container identity."""
import plistlib
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from experiment_t52_probe_signature import BUNDLE, validate_candidate


class ProbeCandidateTests(unittest.TestCase):
    def test_named_container_is_required_before_installation(self):
        for container in (None, True, 'another.bundle', BUNDLE):
            entitlements = {'platform-application': True}
            if container is not None:
                entitlements['com.apple.private.security.container-required'] = container
            with self.subTest(container=container), patch('experiment_t52_probe_signature.subprocess.run',
                    return_value=SimpleNamespace(stdout=plistlib.dumps(entitlements))):
                if container == BUNDLE:
                    validate_candidate('/candidate')
                else:
                    with self.assertRaisesRegex(ValueError, 'formal data-container'):
                        validate_candidate('/candidate')


if __name__ == '__main__': unittest.main()
