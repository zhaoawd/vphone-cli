import json,os,time
from pathlib import Path
w=Path(__file__).resolve().parent
p=w.parent/'t51rt/lib/target/Disk.img'
with p.open('rb') as stream:
    start=time.time()
    (w/'reader-live.json').write_text(json.dumps(dict(pid=os.getpid(),path=str(p),startedAt=start)))
    while not (w/'release-reader').exists() and time.time()-start<180:time.sleep(.2)
(w/'reader-released.json').write_text(json.dumps(dict(pid=os.getpid(),releasedAt=time.time())))
