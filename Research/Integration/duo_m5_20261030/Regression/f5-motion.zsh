#!/bin/zsh
# Use an animated local Safari page to distinguish repeated presentation
# samples from a static foreground. The sampler records request time bounds.
set -euo pipefail
unsetopt BG_NICE
reg="${0:a:h}"
source "$reg/host-request.zsh"
source "$reg/rpc-request.zsh"
root="$(cd "$reg/../../../.." && pwd)"
socket=$(vphone_acceptance_socket "$root" "${1:?acceptance socket required}")
out="${2:?new output required}"
out="${out:A}"
expected="${3:?daemon SHA-256 required}"
bind="${4:?host IPv4 address on guest network required}"
capture="${5:-}"
clock_option="${6:-}"
capture_args=()
if [[ -n "$capture" ]]; then
    [[ "$capture" == --guest=native || "$capture" == --guest=luma || "$capture" == --guest=screenshot ]] || {
        print -u2 'Expected --guest=native, --guest=luma or --guest=screenshot'
        exit 2
    }
    capture_args=("$capture")
fi
if [[ -n "$clock_option" ]]; then
    [[ "$clock_option" == --guest-clock ]] || exit 2
    capture_args+=("$clock_option")
fi
[[ "$out" == "$root/.build/"* && ! -e "$out" ]]
mkdir "$out"
node --input-type=module - "$bind" "$out" <<'JS' &
import http from 'node:http';
import fs from 'node:fs';
import net from 'node:net';
import { randomUUID } from 'node:crypto';
const [bind, out] = process.argv.slice(2);
if (net.isIP(bind) !== 4 || !bind.startsWith('192.168.')) throw Error('Expected the local VM network address');
const route = '/' + randomUUID();
const server = http.createServer((req, res) => {
    if (req.url === route) {
        res.setHeader('Content-Type', 'text/html');
        res.setHeader('Cache-Control', 'no-store');
        res.end(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;background:#152b48;color:white;font:12vw monospace}canvas{position:fixed;inset:0;width:100%;height:100%}</style>
<canvas width="400" height="400"></canvas><script>
const c=document.querySelector('canvas').getContext('2d'); let last=-1;
function draw(t){const n=Math.floor(t/100);if(n!==last){last=n;
c.fillStyle='#152b48';c.fillRect(0,0,400,400);c.fillStyle='#70d4ad';c.fillRect((n%17)*17,130,100,110);
c.fillStyle='white';c.font='64px monospace';c.fillText(String(n),65,325);
fetch(location.pathname+'/tick',{method:'POST',body:String(n)}).catch(()=>{});}requestAnimationFrame(draw);}
requestAnimationFrame(draw);</script>`);
    } else if (req.method === 'POST' && req.url === route + '/tick') {
        let data = '';
        req.on('data', chunk => { data += chunk; if (data.length > 16) req.destroy(); });
        req.on('end', () => {
            if (/^\d+$/.test(data)) fs.appendFileSync(out + '/ticks.tsv', Date.now() + '\t' + data + '\n');
            res.end();
        });
    } else res.writeHead(404).end();
});
server.listen(0, bind, () => fs.writeFileSync(out + '/page.txt', `http://${bind}:${server.address().port}${route}\n`));
JS
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for i in {1..20}; do [[ ! -s "$out/page.txt" ]] || break; sleep .1; done
[[ -s "$out/page.txt" ]]
node "$reg/f5-clock.mjs" "$socket" "$out/samples" "$expected" --settle=2400 --observe=1800 \
    --lock-rotation --match-panel-orientation --check-panel --app=com.apple.mobilesafari "--page=$(cat "$out/page.txt")" "${capture_args[@]}" portrait
[[ $(wc -l < "$out/ticks.tsv") -ge 20 ]]
vphone_host_request "$socket" "$(vphone_rpc_request files.read \
    '{"path":"/var/mobile/Library/Caches/vphone-folddisplay.log","limit":4194304}')" \
    | jq -er '.result | select(.truncated == false and .encoding == "utf8") | .content' > "$out/folddisplay.log"
node "$reg/f5-clock-report.mjs" "$out/samples" > "$out/frames.tsv"
node "$reg/f5-clock-report.mjs" "$out/samples" --timing > "$out/timing.tsv"
node "$reg/f5-motion-ticks.mjs" "$out" > "$out/animation.tsv"
if [[ -n "$capture" ]]; then
    node "$reg/f5-clock-report.mjs" "$out/samples" --dual > "$out/dual.tsv"
fi
node "$reg/f5-handoff-report.mjs" "$out/samples" "$out/folddisplay.log" --require-handoff > "$out/handoff.tsv"
