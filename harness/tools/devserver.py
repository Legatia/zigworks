"""A 127.0.0.1 server with the desk's URL layout, for the avatar's dev pages.

usage: python3 -I tools/devserver.py PORT DATA [--csp POLICY | --no-csp]

  GET  /desk/static/FILE   -> harness/src/desk/FILE (avatar.js, fit.js, vendor/)
  GET  /desk/avatars/PATH  -> DATA/avatars/PATH
  GET  /desk/assets/PATH   -> DATA/desk-assets/PATH
  GET  /tools/PATH         -> harness/tools/PATH
  POST /save/PATH          -> DATA/PATH, PATH under avatars/, desk-assets/ or
                              debug/ (the request body, up to 64 MB)
  POST /csp-report         -> appended to DATA/csp-reports.log (up to 1 MB)

It prints a token for this run. The dev pages that save take it from their
URL's fragment (#token=...) and send it as an X-Dev-Token header; a POST
without it is refused. A custom header needs a CORS preflight, which this
server doesn't answer, so another web page in the browser can't write here.
Requests must name this server as Host (127.0.0.1:PORT or localhost:PORT),
and a POST's Origin must be this server. /csp-report takes only the
browser's own report type (application/csp-report), which a page can't
send to another origin without a preflight either.

Every response carries a Content-Security-Policy (the default below, which
reports to /csp-report), so the pages run under the rules the desk has.
Dev only: harness serves the desk itself.
"""
import hmac
import os
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HARNESS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DEFAULT_CSP = (
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
    "img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; "
    "style-src 'self'; report-uri /csp-report"
)
# where /save/ may write, under DATA
SAVE_DIRS = ("avatars", "desk-assets", "debug")
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
    token = secrets.token_urlsafe(32)
    hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
    origins = {"http://" + h for h in hosts}
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

        def answer(self, code, text):
            body = text.encode()
            self.head(code, "text/plain; charset=utf-8", len(body))
            self.wfile.write(body)

        def host_ok(self):
            if self.headers.get("Host", "") in hosts:
                return True
            self.answer(403, "not this server's name")
            return False

        def do_GET(self):
            if not self.host_ok():
                return
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
            self.answer(404, "not found")

        def do_POST(self):
            if not self.host_ok():
                return
            path = self.path.split("?", 1)[0]
            origin = self.headers.get("Origin")
            if origin is not None and origin not in origins:
                return self.answer(403, "another origin")
            n = int(self.headers.get("Content-Length", "0") or 0)
            if n <= 0 or n > 64 << 20:
                return self.answer(400, "size")
            try:
                if path == "/csp-report":
                    # the browser's own report; not a type another page can send here
                    if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/csp-report" or n > 64 << 10:
                        return self.answer(403, "not a CSP report")
                    log = os.path.join(data, "csp-reports.log")
                    if os.path.exists(log) and os.path.getsize(log) > 1 << 20:
                        return self.answer(413, "the log is full")
                    body = self.rfile.read(n)
                    with open(log, "ab") as f:
                        f.write(body + b"\n")
                elif path.startswith("/save/"):
                    given = self.headers.get("X-Dev-Token", "")
                    if origin is None or not hmac.compare_digest(given.encode(), token.encode()):
                        return self.answer(403, "no token")
                    rel = path[len("/save/"):]
                    if rel.split("/", 1)[0] not in SAVE_DIRS or "/" not in rel:
                        return self.answer(403, "saves go under " + ", ".join(SAVE_DIRS))
                    p = inside(os.path.join(data, rel.split("/", 1)[0]), rel.split("/", 1)[1])
                    body = self.rfile.read(n)
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p + ".part", "wb") as f:
                        f.write(body)
                    os.replace(p + ".part", p)
                else:
                    return self.answer(404, "no such path")
            except Exception as e:
                return self.answer(400, str(e))
            self.answer(200, "saved")

        def log_message(self, *a):
            pass

    print("token %s" % token, flush=True)
    print("open pages with #token=%s, e.g. http://127.0.0.1:%d/tools/fit-pack.html?pack=NAME#token=%s" % (token, port, token), flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    main()
