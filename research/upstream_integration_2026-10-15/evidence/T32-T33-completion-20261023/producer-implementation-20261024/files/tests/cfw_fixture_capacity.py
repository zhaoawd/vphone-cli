"""Capacity observation for disposable byte-sized APFS driver fixtures only."""

def model_capacity(module):
    with module.open('a') as output:
        output.write('''
_native_require_free_space = require_free_space
def require_free_space(paths, minimum=50 << 30):
    from types import SimpleNamespace
    from unittest.mock import patch
    with patch.object(os, 'statvfs', return_value=SimpleNamespace(f_bavail=64 << 30, f_frsize=1)):
        return _native_require_free_space(paths, minimum)
''')
