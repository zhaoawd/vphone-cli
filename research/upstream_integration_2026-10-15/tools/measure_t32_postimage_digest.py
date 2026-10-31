#!/usr/bin/env python3
"""Measure one existing complete postimage digest with a 90-second bound."""
import cProfile
import json
from pathlib import Path
import pstats
import signal
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'.build/t32-t33-completion-20261023/exp-bounded-preflight-20261024'
IMAGE=ROOT/'.build/t32q-20261024/.cfw-history/20261024T081630Z-kbuBz8Io/guest-postimage.img'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence


def expired(*_):raise TimeoutError('single digest exceeded 90 seconds')


def main():
    expected=json.loads((ROOT/'.build/t32-t33-completion-20261023/origin-identity-acceptance-20261024-r2/execution/regular/reapplied.json').read_text())['independentAudit']['publicationImageSHA256']
    result=dict(scope='one real postimage; production Python digest under cProfile',bytes=IMAGE.stat().st_size,
                deadlineSeconds=90,completed=False,VMStarts=0,CFWInstalled=False)
    profile=cProfile.Profile();signal.signal(signal.SIGALRM,expired);start=time.monotonic();cpu=time.process_time()
    signal.setitimer(signal.ITIMER_REAL,90)
    try:
        value=profile.runcall(evidence.digest,IMAGE)
        if value!=expected:raise ValueError('Retained postimage differs from sealed publication')
        result.update(completed=True,sha256=value,matchesSealedPublication=True)
    except Exception as error:result['error']=str(error)
    finally:
        signal.setitimer(signal.ITIMER_REAL,0)
        result.update(elapsedSeconds=time.monotonic()-start,cpuSeconds=time.process_time()-cpu)
        profile.dump_stats(str(OUT/'single-postimage-digest.prof'))
        with (OUT/'single-postimage-digest-profile.txt').open('x') as out:
            pstats.Stats(profile,stream=out).sort_stats('cumulative').print_stats(18)
        (OUT/'single-postimage-digest.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result));return 0 if result['completed'] else 1


if __name__=='__main__':raise SystemExit(main())
