"""Temporary PR validation probe; removed after checking failure feedback."""
import unittest

class A4CIFailureProbe(unittest.TestCase):
    def test_deliberate_failure(self):
        self.fail('A4 remote deliberate failure probe')
