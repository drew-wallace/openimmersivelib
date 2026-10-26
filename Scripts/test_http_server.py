#!/usr/bin/env python3
"""Local-only deterministic range fixture for transport/cancellation tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

SIZE = 64 * 1024 * 1024
PATTERN = bytes(range(251))

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        try:
            begin, end = map(int, self.headers['Range'].removeprefix('bytes=').split('-'))
            end = min(end, SIZE - 1)
            response_begin = begin + (1 if self.path == "/wrong-range" else 0)
            if self.path == '/slow-probe' or (self.path == '/slow' and end > 1):
                time.sleep(2)
            if self.path == '/ignores-range':
                self.send_response(200)
                self.send_header('Content-Length', str(SIZE))
                self.end_headers()
                return
            if self.path == '/truncated':
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {response_begin}-{end}/{SIZE}')
                self.send_header('Content-Length', str(end - begin + 1))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(b'x')
                return
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {response_begin}-{end}/{SIZE}')
            self.send_header('Content-Length', str(end - begin + 1))
            self.send_header('Connection', 'close')
            self.end_headers()
            position = begin
            while position <= end:
                count = min(65536, end - position + 1)
                start = position % 251
                self.wfile.write((PATTERN * ((start + count + 250)//251))[start:start+count])
                position += count
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(server.server_address[1], flush=True)
server.serve_forever()
