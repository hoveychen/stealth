# Serves a bare page at any path and /echo, which answers the request's Referer
# as JSON. Used by expr-detached-base-referrer.js.
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path.startswith('/echo'):
            body=json.dumps({'referer':self.headers.get('Referer')}).encode(); ct='application/json'
        else:
            body=b'<!doctype html><html><head><title>p</title></head><body><div id=host></div></body></html>'; ct='text/html'
        self.send_response(200); self.send_header('Content-Type',ct); self.send_header('Content-Length',str(len(body))); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
