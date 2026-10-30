// Touch probe page for F3: every touch start is reported back with its
// client coordinates and the viewport, one JSON line per touch in touches.log.
import http from 'node:http';
import fs from 'node:fs';
const log = new URL('./touches.log', import.meta.url);
const page = `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>touch</title><style>html,body{margin:0;height:100%;background:#123;color:#fff;font:20px -apple-system;touch-action:none}
#o{position:fixed;left:8px;top:8px}</style><div id=o>ready</div><script>
document.addEventListener('touchstart', e => { const t = e.changedTouches[0];
  const r = {x: t.clientX, y: t.clientY, w: innerWidth, h: innerHeight, sw: screen.width, sh: screen.height, o: screen.orientation ? screen.orientation.type : ''};
  document.getElementById('o').textContent = JSON.stringify(r);
  fetch('/t', {method: 'POST', body: JSON.stringify(r)}); e.preventDefault(); }, {passive: false});
</script>`;
http.createServer((q, s) => {
  if (q.method === 'POST' && q.url === '/t') {
    let b = ''; q.on('data', d => b += d);
    q.on('end', () => { fs.appendFileSync(log, JSON.stringify({at: Date.now() / 1000, ...JSON.parse(b)}) + '\n'); s.end('ok'); });
  } else { s.setHeader('content-type', 'text/html'); s.end(page); }
}).listen(18766, '192.168.64.1');
