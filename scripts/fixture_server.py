#!/usr/bin/env python3
"""Local-only fixture server with byte-range support for the AVPlayer UI test."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import os

ROOT = Path(__file__).resolve().parent.parent / 'tests/Fixtures'

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        requested = Path(self.translate_path(self.path)).resolve()
        if ROOT.resolve() not in requested.parents:
            self.send_error(404)
            return
        if not requested.is_file() or not self.headers.get('Range'):
            return super().do_GET()
        size = requested.stat().st_size
        match = re.fullmatch(r'bytes=(\d*)-(\d*)', self.headers.get('Range', ''))
        if not match or not any(match.groups()):
            self.send_error(416)
            return
        first, last = match.groups()
        start = int(first) if first else max(0, size - int(last))
        end = min(size - 1, int(last)) if last and first else size - 1
        if start > end or start >= size:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{size}')
            self.end_headers()
            return
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(str(requested)))
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        with requested.open('rb') as stream:
            stream.seek(start)
            self.wfile.write(stream.read(end - start + 1))

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('LIVE_FIXTURE_PORT', '8765'))), Handler).serve_forever()
