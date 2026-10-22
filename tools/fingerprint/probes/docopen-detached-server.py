# Serves the page for expr-docopen-detached.js: /p?when=parse|load&kind=chd|dp&op=open|write
# runs document.open/write/close on a document with no browsing context
# (createHTMLDocument or DOMParser) either from an inline script while the
# page is still parsing, or from a task after the page's load event, and
# leaves its readings in window.__R once the page has settled.
import http.server, sys

PAGE = r'''<!doctype html><html><head><title>host</title>
<script>
(() => {
  const q = new URLSearchParams(location.search);
  const when = q.get('when'), kind = q.get('kind'), op = q.get('op') || 'open';
  const R = window.__R = {when, kind, op, c: {}};
  const bump = (k) => R.c[k] = (R.c[k] || 0) + 1;
  window.addEventListener('load', () => bump('winLoad'));
  window.addEventListener('ping', () => bump('winPing'));
  document.addEventListener('DOMContentLoaded', () => bump('dcl'));
  document.addEventListener('readystatechange', () => bump('rsc:' + document.readyState));
  document.addEventListener('ping', () => bump('docPing'));
  window.onmessage = () => bump('winOnMessage');

  const run = () => {
    const d = kind === 'dp'
      ? new DOMParser().parseFromString('<p id=old>old</p>', 'text/html')
      : document.implementation.createHTMLDocument('t');
    d.addEventListener('ping', () => bump('dPing'));
    if (d.body) d.body.addEventListener('ping', () => bump('dBodyPing'));
    const s = R.step = {hostReadyBefore: document.readyState};
    try {
      if (op === 'open') s.openRet = d.open() === d ? 'self' : String(d.open);
      s.readyAfterOpen = d.readyState;
      s.childrenAfterOpen = d.childNodes.length;
      d.write('<html><head><base href="https://evil.example/d/"><title>W</title></head><body><p id=w>hi</p>' +
        '<scr' + 'ipt>window.__ran=(window.__ran||0)+1;document.title="pwn"</scr' + 'ipt>' +
        '<img src="/nonexistent.png" onerror="window.__imgerr=1"></body></html>');
      s.readyAfterWrite = d.readyState;
      d.close();
    } catch (e) { s.err = String(e); }
    s.readyAfterClose = d.readyState;
    s.dTitle = d.title;
    s.dW = d.getElementById('w') ? d.getElementById('w').textContent : null;
    s.dOld = !!d.getElementById('old');
    s.dBaseURI = d.baseURI;
    s.dURL = d.URL;
    s.dHtml = d.documentElement ? d.documentElement.outerHTML.slice(0, 300) : null;
    s.dHasScript = d.getElementsByTagName('script').length;
    s.hostReadyAfter = document.readyState;
    s.hostURL = document.URL;
    s.hostBaseURI = document.baseURI;
    s.hostTitle = document.title;
    s.hostBody = !!document.body;
    window.dispatchEvent(new Event('ping'));
    document.dispatchEvent(new Event('ping'));
    d.dispatchEvent(new Event('ping'));
    if (d.body) d.body.dispatchEvent(new Event('ping'));
    window.__d = d;
  };
  if (when === 'parse') run();
  else window.addEventListener('load', () => setTimeout(run, 0));
  window.__done = new Promise((res) => window.addEventListener('load', () => setTimeout(() => {
    window.postMessage('m', '*');
    setTimeout(() => {
      window.dispatchEvent(new Event('ping'));
      document.dispatchEvent(new Event('ping'));
      R.fin = {ran: window.__ran || 0, imgerr: window.__imgerr || 0,
        hostReady: document.readyState, hostURL: document.URL, hostTitle: document.title,
        afterDiv: !!document.getElementById('after'),
        hostChildren: document.body ? document.body.children.length : -1,
        dReady: window.__d && window.__d.readyState};
      res(R);
    }, 800);
  }, 200)));
})();
</script></head><body><div id=before>b</div><div id=after>a</div></body></html>'''


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith('/p'):
            body, ct, code = PAGE.encode(), 'text/html', 200
        else:
            body, ct, code = b'', 'text/plain', 404
        self.send_response(code)
        self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
