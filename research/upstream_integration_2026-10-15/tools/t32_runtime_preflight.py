"""macOS host-control checks that must run before any VM or helper start."""
from pathlib import Path

# Darwin sockaddr_un.sun_path has 104 bytes, including the trailing NUL.
MACOS_SUN_PATH_BYTES=104


def validate_control_socket(vm,socket_name='vphone.sock'):
    path=str(Path(vm).absolute()/socket_name)
    count=len(path.encode('utf-8'))+1
    if '\0' in path or count>MACOS_SUN_PATH_BYTES:
        raise ValueError('invalid or oversized socket path: '+str(count)+' bytes including NUL; maximum '+str(MACOS_SUN_PATH_BYTES))
    return dict(path=path,bytesIncludingNul=count,maximumIncludingNul=MACOS_SUN_PATH_BYTES)
