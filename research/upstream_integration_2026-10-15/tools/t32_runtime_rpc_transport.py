"""Transport for the next separately approved runtime observer; not deployed."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import request as host_request

RPC_TRANSPORT_TIMEOUT = 100


def request(target, payload, recorder, timeout):
    # The observer must wait beyond the host's 75-second RPC budget.
    if payload.get('t') == 'rpc':
        timeout = max(timeout, RPC_TRANSPORT_TIMEOUT)
    return host_request(target, payload, recorder, timeout)
