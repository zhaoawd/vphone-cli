import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

binary=str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='vphone-export-existing-') as temporary:
    root=Path(temporary); source=root/'library'/'source'; source.mkdir(parents=True)
    manifest=dict(platformType='vresearch101', machineIdentifier=b'abc', cpuCount=2,
        memorySize=2 << 30, screenConfig=dict(width=1290,height=2796,pixelsPerInch=460,scale=3.0),
        networkConfig=dict(mode='nat',macAddress=''), diskImage='Disk.img',nvramStorage='nvram.bin',sepStorage='SEPStorage')
    (source/'config.plist').write_bytes(plistlib.dumps(manifest))
    (source/'Disk.img').write_bytes(b'fixture data')
    for backend in ('system-tar','native'):
        output=root/f'{backend}.tzst'; output.write_bytes(b'keep existing archive')
        result=subprocess.run([binary,'vm','export','source','--library-root',str(source.parent),
            '--out',str(output),'--archive-backend',backend],capture_output=True,timeout=30)
        unchanged=output.read_bytes()==b'keep existing archive'
        print(json.dumps(dict(backend=backend,exit=result.returncode,existing_unchanged=unchanged)),flush=True)
        assert result.returncode!=0 and unchanged, 'existing output was overwritten'
