"""Regress the actual diskutil schema observed during T32/T33 VM acceptance."""
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))

from patchers.volume_state import volume_read_only


class VolumeStateTests(unittest.TestCase):
    def test_both_explicit_volume_schemas_and_consistent_pairs(self):
        for info, expected in [
            ({'ReadOnlyVolume': True}, True),
            ({'ReadOnlyVolume': False}, False),
            ({'WritableVolume': False, 'WritableMedia': False, 'Writable': False}, True),
            ({'WritableVolume': True}, False),
            ({'ReadOnlyVolume': True, 'WritableVolume': False}, True),
            ({'ReadOnlyVolume': False, 'WritableVolume': True}, False),
        ]:
            with self.subTest(info=info):
                self.assertIs(volume_read_only(info), expected)

    def test_media_or_generic_flags_do_not_establish_volume_state(self):
        for info in [{}, {'WritableMedia': False}, {'Writable': False},
                     {'ReadOnlyMedia': True}, []]:
            with self.subTest(info=info):
                with self.assertRaisesRegex(ValueError, 'unknown'):
                    volume_read_only(info)

    def test_contradictions_are_rejected(self):
        for value in (True, False):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, 'contradicts'):
                    volume_read_only({'ReadOnlyVolume': value, 'WritableVolume': value})

    def test_malformed_field_cannot_be_hidden_by_a_valid_alternative(self):
        for key in ('ReadOnlyVolume', 'WritableVolume'):
            for value in (None, 0, 1, 'true', [], {}):
                other = 'WritableVolume' if key == 'ReadOnlyVolume' else 'ReadOnlyVolume'
                with self.subTest(key=key, value=value):
                    with self.assertRaisesRegex(ValueError, 'unknown'):
                        volume_read_only({key: value, other: False})
