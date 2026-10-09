#!/usr/bin/env python3
"""T46 evidence harness. Production CLI fixtures are distinct from UI and VM acceptance."""
import argparse, hashlib, http.server, json, os, pathlib, signal, subprocess, threading, time
BASE = pathlib.Path('/private/tmp/vphone-b24-t46')
def save(path, obj):
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n')
def processes():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,command='], capture_output=True, text=True, check=True)
    rows = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) == 5:
            rows.append(dict(pid=int(fields[0]), ppid=int(fields[1]), pgid=int(fields[2]), stat=fields[3], command=fields[4]))
    return rows
def descendants(rows, pid):
    ids = {pid}
    while True:
        new = ids | {r['pid'] for r in rows if r['ppid'] in ids}
        if new == ids: return [r for r in rows if r['pid'] in ids or r['pgid'] == pid]
        ids = new
def tracked_processes(rows, pid, tracked):
    current = descendants(rows, pid)
    for row in current:
        tracked.setdefault(row['pid'], row['command'])
    # Production create starts stage workers in their own groups. Retain
    # previously observed identities after their parent exits/reparents.
    return [row for row in rows if row in current or tracked.get(row['pid']) == row['command']]
def snapshot(path):
    try:
        data = path.read_bytes()
        stat = path.stat()
        return dict(path=str(path), size=len(data), inode=stat.st_ino, sha256=hashlib.sha256(data).hexdigest(), tail=data[-12000:].decode('utf-8', 'replace'))
    except FileNotFoundError: return dict(path=str(path), missing=True)
class SlowServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, directory):
        super().__init__(('127.0.0.1', 0), SlowHandler)
        self.directory = directory
        self.started = time.monotonic()
        self.stop_event = threading.Event()
        self.request_seen = threading.Event()
        self.lock = threading.Lock()
        self.events = []
        self.bytes_sent = 0
        self.transferred_bytes = 0
    def record(self, **event):
        with self.lock:
            self.events.append(dict(elapsed=time.monotonic()-self.started, **event))
            save(self.directory/'http-events.json', self.events)
class SlowHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.server.record(event='request', path=self.path, range=self.headers.get('Range'), client=self.client_address[0])
        self.server.request_seen.set()
        total = 64 << 20
        start, end = 0, total-1
        ranged = self.headers.get('Range')
        if ranged:
            unit, _, interval = ranged.partition('=')
            first, _, last = interval.partition('-')
            if unit != 'bytes' or not first.isdigit() or (last and not last.isdigit()):
                self.send_error(416); return
            start, end = int(first), min(int(last) if last else total-1, total-1)
            if start > end:
                self.send_error(416); return
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(end-start+1))
        self.send_header('Accept-Ranges', 'bytes')
        if ranged: self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
        self.end_headers()
        count = 0
        # Incomplete synthetic transfer. It cannot become a valid IPSW or reach patch/restore.
        try:
            while not self.server.stop_event.wait(.1):
                with self.server.lock:
                    remaining = min((4 << 20)-self.server.bytes_sent, end-start+1-count)
                    if remaining <= 0: continue
                    chunk = (b'T46 incomplete transfer fixture\n' * 1024)[:remaining]
                    self.server.bytes_sent += len(chunk)
                self.wfile.write(chunk)
                self.wfile.flush()
                count += len(chunk)
                with self.server.lock:
                    self.server.transferred_bytes += len(chunk)
        except (BrokenPipeError, ConnectionResetError): pass
        self.server.record(event='connection-ended', path=self.path, bytes_sent=count)
def start_server(directory):
    directory.mkdir(parents=True, exist_ok=False)
    server = SlowServer(directory)
    port = server.server_port
    ready = dict(scope='controlled HTTP fixture; no real firmware', directory=str(directory), port=port,
                 iphone_source=f'http://127.0.0.1:{port}/T46-iPhone.ipsw', cloudos_source=f'http://127.0.0.1:{port}/T46-cloudOS.ipsw')
    save(directory/'server-ready.json', ready)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, ready
def cli_case(args):
    directory = BASE/args.case
    server, ready = start_server(directory)
    cli = pathlib.Path(args.app)/'Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli'
    cache = directory/'data'
    library = directory/'library'
    env = {k:v for k,v in os.environ.items() if k.lower() not in {"http_proxy", "https_proxy", "all_proxy"}}
    env.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    env.update(VPHONE_ROOT=str(cache), VPHONE_LIBRARY_ROOT=str(library), VPHONE_PYTHON=args.python)
    command = [str(cli), 'vm', 'create', 't46-create', '--library-root', str(library), '--disk-size', '8',
               '--variant', 'regular', '--iphone-source', ready['iphone_source'], '--cloudos-source', ready['cloudos_source'],
               '--root-popup', '--prepare-backend', 'script', '-vvv']
    start = time.monotonic()
    output = directory/'create.log'
    with output.open('wb') as log:
        child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        report = dict(scope='real signed production CLI with controlled incomplete HTTP input; no UI or VM', command=command,
                      environment={k:env[k] for k in ['VPHONE_ROOT','VPHONE_LIBRARY_ROOT','VPHONE_PYTHON']}, pid=child.pid,
                      cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest())
        print(json.dumps(dict(pid=child.pid, **ready)), flush=True)
        try:
            until = time.monotonic()+30
            while server.transferred_bytes < 65536 and child.poll() is None and time.monotonic()<until: time.sleep(.05)
            report['http_request_seen'] = server.request_seen.is_set()
            report['http_bytes_transferred_before_signal'] = server.transferred_bytes
            tracked = {}
            report['before_signal'] = tracked_processes(processes(), child.pid, tracked)
            report['before_log'] = snapshot(output)
            if child.poll() is None:
                report['signal_elapsed'] = time.monotonic()-start
                os.killpg(child.pid, signal.SIGINT)
            report['exit_code'] = child.wait(timeout=30)
            report['exit_elapsed'] = time.monotonic()-start
            until = time.monotonic()+5
            while time.monotonic()<until:
                rows = tracked_processes(processes(), child.pid, tracked)
                if not rows: break
                time.sleep(.05)
            report['after_processes'] = rows
            result = subprocess.run([str(cli), 'vm', 'create-status', 't46-create', '--library-root', str(library), '--json'],
                                    env=env, capture_output=True, text=True, timeout=15)
            (directory/'create-status.stdout.json').write_text(result.stdout)
            (directory/'create-status.stderr.log').write_text(result.stderr)
            report['status_exit_code'] = result.returncode
            if result.returncode == 0: report['status'] = json.loads(result.stdout)
            report['files'] = [{'path':str(p.relative_to(directory)), 'size':p.stat().st_size, 'allocated_bytes':p.stat().st_blocks*512}
                               for p in directory.rglob('*') if p.is_file() and p.name != 'result.json']
            report['final_log'] = snapshot(output)
            status = report.get('status', {})
            report['passed'] = bool(report['http_request_seen'] and report['http_bytes_transferred_before_signal'] >= 65536 and report['exit_code'] != 0 and not rows
                and status.get('overall_status') == 'interrupted' and not status.get('live',{}).get('create_run_in_progress')
                and not status.get('live',{}).get('bundle_lock_held') and 'interrupted by SIGINT' in report['final_log'].get('tail',''))
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
                report['forced_cleanup'] = True
            server.stop_event.set(); server.shutdown(); server.server_close()
            save(directory/'result.json', report)
    print(json.dumps(dict(result=str(directory/'result.json'), passed=report.get('passed',False))), flush=True)
    return 0 if report.get('passed') else 1
def serve(args):
    server, ready = start_server(BASE/args.case)
    print(json.dumps(ready), flush=True)
    try: time.sleep(args.seconds)
    except KeyboardInterrupt: pass
    finally: server.stop_event.set(); server.shutdown(); server.server_close()
def observe(args):
    directory=BASE/args.case
    directory.mkdir(parents=True, exist_ok=True)
    result=dict(scope=args.scope, started=time.time(), pid=args.pid, samples=[])
    start=time.monotonic()
    tracked={}
    with (directory/'samples.ndjson').open('w') as stream:
        while time.monotonic()-start<args.seconds:
            sample=dict(elapsed=time.monotonic()-start, processes=tracked_processes(processes(),args.pid,tracked), logs=[snapshot(pathlib.Path(p)) for p in args.log])
            result['samples'].append(sample)
            stream.write(json.dumps(sample)+'\n');stream.flush()
            save(directory/'observation-state.json',dict(scope=args.scope,started=result['started'],pid=args.pid,samples=[sample]))
            if len(result['samples']) == 1: save(directory/'observation.json',result)
            time.sleep(.1)
    save(directory/'observation.json',result)
    print(json.dumps(dict(output=str(directory/'observation.json'),samples=len(result['samples']))))
def wait_observe(args):
    directory=BASE/args.case
    directory.mkdir(parents=True, exist_ok=False)
    until=time.monotonic()+30
    while time.monotonic()<until:
        rows=processes()
        creates=[row for row in rows if f'/Contents/MacOS/vphone-cli vm create {args.name} ' in row['command'] and args.library in row['command']]
        if creates:
            create=creates[0]
            initial=descendants(rows,create['pid'])
            if any('aria2c ' in row['command'] or 'curl ' in row['command'] for row in initial):
                ready=dict(app_pid=args.pid,create_pid=create['pid'],initial_processes=initial,log=args.log,scope='real UI')
                save(directory/'observer-ready.json',ready)
                print(json.dumps(dict(ready=str(directory/'observer-ready.json'),create_pid=create['pid'],initial_processes=initial)),flush=True)
                return observe(args)
        time.sleep(.1)
    save(directory/'readiness-failed.json',dict(error='create download worker not observed within 30 seconds'))
    return 1
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='mode',required=True)
    c=sub.add_parser('cli-case');c.add_argument('--case',required=True);c.add_argument('--app',required=True);c.add_argument('--python',required=True)
    c=sub.add_parser('serve');c.add_argument('--case',required=True);c.add_argument('--seconds',type=float,default=180)
    c=sub.add_parser('observe');c.add_argument('--case',required=True);c.add_argument('--pid',required=True,type=int);c.add_argument('--seconds',type=float,default=30);c.add_argument('--log',action='append',default=[]);c.add_argument('--scope',required=True,choices=['real UI','real VM','real child fixture'])
    c=sub.add_parser('wait-observe');c.add_argument('--case',required=True);c.add_argument('--pid',required=True,type=int);c.add_argument('--name',required=True);c.add_argument('--library',required=True);c.add_argument('--seconds',type=float,default=30);c.add_argument('--log',action='append',default=[]);c.set_defaults(scope='real UI')
    args=parser.parse_args()
    return {'cli-case':cli_case,'serve':serve,'observe':observe,'wait-observe':wait_observe}[args.mode](args) or 0
if __name__=='__main__': raise SystemExit(main())
