import os, signal, subprocess, tempfile, time, pathlib
with tempfile.TemporaryDirectory(prefix='vphone-import-cancel-') as t:
    root=pathlib.Path(t); fifo=root/'input.tar'; os.mkfifo(fifo)
    library=root/'library'
    p=subprocess.Popen(['.build/debug/vphone-cli','vm','import',str(fifo),'--library-root',str(library),'--name','copy'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+5
        while not list(library.glob('.import-*')):
            assert p.poll() is None, p.communicate()
            assert time.monotonic()<deadline
            time.sleep(.01)
        p.send_signal(signal.SIGTERM)
        out,err=p.communicate(timeout=5)
        leftovers=list(library.glob('.import-*'))
        print('exit',p.returncode,'staging_count',len(leftovers),'published',(library/'copy').exists())
        assert not leftovers, 'cancelled import left private staging'
    finally:
        if p.poll() is None: p.kill(); p.wait()
