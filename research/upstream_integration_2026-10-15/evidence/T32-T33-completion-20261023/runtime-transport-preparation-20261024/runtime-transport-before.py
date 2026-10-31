"""Transport for the next separately approved runtime observer; not deployed."""
from host_control_client import request as host_request


def request(target, payload, recorder, timeout):
    return host_request(target, payload, recorder, timeout)
