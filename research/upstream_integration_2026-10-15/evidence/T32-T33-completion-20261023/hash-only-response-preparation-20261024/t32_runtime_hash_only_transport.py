"""Preparation for hash-only binary logs in the next approved runtime plan."""
import base64
import copy
import hashlib

from t32_runtime_rpc_transport import request as budgeted_request


def hash_field(container, key):
    value = container.get(key)
    if not isinstance(value, str):
        raise ValueError('Binary response field is not a base64 string: '+key)
    data = base64.b64decode(value, validate=True)
    container.pop(key)
    container[key+'Bytes'] = len(data)
    container[key+'SHA256'] = hashlib.sha256(data).hexdigest()


class HashOnlyRecorder:
    def __init__(self, delegate):
        self.delegate = delegate

    def record(self, target, payload, response):
        logged = copy.deepcopy(response)
        for key in ('data', 'image'):
            if isinstance(logged.get(key), str):
                hash_field(logged, key)
        if payload.get('t') == 'rpc' and logged.get('ok') is True:
            method = payload.get('method')
            if method in ('files.read', 'ui.describe'):
                result = logged.get('result')
                if not isinstance(result, dict):
                    raise ValueError('Binary RPC response has no result object')
                if method == 'files.read':
                    params = payload.get('params', {})
                    if result.get('encoding') == 'base64':
                        hash_field(result, 'content')
                    elif params.get('binary') is True or params.get('path') == '/private/xarts/AA.gl':
                        raise ValueError('Binary file read returned an unexpected encoding')
                else:
                    screenshot = result.get('screenshot')
                    if not isinstance(screenshot, dict):
                        raise ValueError('UI description has no screenshot object')
                    hash_field(screenshot, 'data')
        self.delegate.record(target, payload, logged)


def request(target, payload, recorder, timeout):
    return budgeted_request(target, payload, HashOnlyRecorder(recorder), timeout)
