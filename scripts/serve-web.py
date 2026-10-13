"""Local preview of the GitHub Pages subpath; serves only build/web."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8080)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent / 'build' / 'web'

class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      '.mjs': 'text/javascript', '.js': 'text/javascript',
                      '.wasm': 'application/wasm'}
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def do_GET(self):
        # Do not reuse a cached MIME type after changing preview server settings.
        for header in ('If-Modified-Since', 'If-None-Match'):
            if header in self.headers:
                del self.headers[header]
        if not urlsplit(self.path).path.startswith('/Household_Ledger/'):
            self.send_error(404)
            return
        self.path = self.path[len('/Household_Ledger'):]
        super().do_GET()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

print(f'Preview: http://localhost:{args.port}/Household_Ledger/', flush=True)
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
