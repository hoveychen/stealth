# Serves the page and resources for expr-xhr-document.js: /x/doc.xml (XML),
# /x/bad.xml (malformed XML), /x/doc.html (HTML with a <base>), /x/text.xml
# (text/xml), /x/pic.svg (image/svg+xml), anything else
# a bare HTML page; /x/redir 302s to /x/doc.xml?from=redir.
import http.server, sys
R = {
    '/x/doc.xml': ('application/xml', b'<?xml version="1.0"?><root><a id="i">t</a></root>'),
    '/x/text.xml': ('text/xml', b'<root><a id="i">t</a></root>'),
    '/x/pic.svg': ('image/svg+xml', b'<svg xmlns="http://www.w3.org/2000/svg"><title>S</title></svg>'),
    '/x/bad.xml': ('application/xml', b'<root><a></root>'),
    '/x/doc.html': ('text/html; charset=utf-8', b'<!doctype html><html><head><title>T</title><base href="https://evil.example/d/"></head><body><a href="rel">x</a><script>parent.__ran=1</script></body></html>'),
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith('/x/redir'):
            self.send_response(302); self.send_header('Location', '/x/doc.xml?from=redir'); self.send_header('Content-Length', '0'); self.end_headers(); return
        ct, body = R.get(self.path.split('?')[0], ('text/html', b'<!doctype html><html><head><title>p</title></head><body></body></html>'))
        self.send_response(200); self.send_header('Content-Type', ct); self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
