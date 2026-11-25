"""A 127.0.0.1 server with the desk's URL layout, for the avatar's dev pages.

usage: python3 -I tools/devserver.py PORT DATA [--csp POLICY | --no-csp]

  GET  /desk/static/FILE   -> harness/src/desk/FILE (avatar.js, fit.js, vendor/)
  GET  /desk/avatars/PATH  -> DATA/avatars/PATH
  GET  /desk/assets/PATH   -> DATA/desk-assets/PATH
  GET  /tools/PATH         -> harness/tools/PATH
  POST /save/PATH          -> DATA/PATH (the request body, up to 64 MB)
  POST /csp-report         -> appended to DATA/csp-reports.log

Every response carries a Content-Security-Policy (the default below, which
reports to /csp-report), so the pages run under the rules the desk has.
Dev only: harness serves the desk itself.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HARNESS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DEFAULT_CSP = (
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
    "img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; "
    "style-src 'self'; report-uri /csp-report"
)
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".css": "text/css",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".wav": "audio/wav",
    ".ini": "text/plain; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
}


def inside(root, rel):
    p = os.path.realpath(os.path.join(root, rel))
    if p != os.path.realpath(root) and not p.startswith(os.path.realpath(root) + os.sep):
        raise ValueError("outside")
    return p


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    port, data = int(args[0]), os.path.realpath(args[1])
    csp = DEFAULT_CSP
    if "--no-csp" in args:
        csp = None
    if "--csp" in args:
        csp = args[args.index("--csp") + 1]
    roots = {
        "desk/static": os.path.join(HARNESS, "src", "desk"),
        "desk/avatars": os.path.join(data, "avatars"),
        "desk/assets": os.path.join(data, "desk-assets"),
        "tools": os.path.join(HARNESS, "tools"),
    }

    class H(BaseHTTPRequestHandler):
        def head(self, code, ctype, n):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(n))
            self.send_header("Cache-Control", "no-store")
            if csp:
                self.send_header("Content-Security-Policy", csp)
            self.end_headers()

        def do_GET(self):
            path = self.path.split("?", 1)[0].split("#", 1)[0]
            for prefix, root in roots.items():
                if path.startswith("/" + prefix + "/"):
                    try:
                        p = inside(root, path[len(prefix) + 2:])
                        with open(p, "rb") as f:
                            body = f.read()
                    except Exception:
                        break
                    self.head(200, TYPES.get(os.path.splitext(p)[1].lower(), "application/octet-stream"), len(body))
                    self.wfile.write(body)
                    return
            self.head(404, "text/plain", 9)
            self.wfile.write(b"not found")

        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0"))
            if n <= 0 or n > 64 << 20:
                self.head(400, "text/plain", 4)
                self.wfile.write(b"size")
                return
            body = self.rfile.read(n)
            path = self.path.split("?", 1)[0]
            try:
                if path == "/csp-report":
                    with open(os.path.join(data, "csp-reports.log"), "ab") as f:
                        f.write(body + b"\n")
                elif path.startswith("/save/"):
                    p = inside(data, path[len("/save/"):])
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p + ".part", "wb") as f:
                        f.write(body)
                    os.replace(p + ".part", p)
                else:
                    raise ValueError("no such path")
            except Exception as e:
                msg = str(e).encode()
                self.head(400, "text/plain", len(msg))
                self.wfile.write(msg)
                return
            self.head(200, "text/plain", 5)
            self.wfile.write(b"saved")

        def log_message(self, *a):
            pass

    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    main()
