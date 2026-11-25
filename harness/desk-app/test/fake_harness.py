#!/usr/bin/env python3
"""A stand-in for harness, for the desk app's smoke (scripts/smoke.sh).

It answers as harness's side of the desk does (the spec's "The desktop app
and getting in"), and nothing more:

  fake_harness.py run --home DIR [--port P]
      listens on 127.0.0.1 (desk.json's port, or P), writes
      DIR/state/desk.json, answers GET /alive; when DIR/state/open-request
      appears, deletes it and writes DIR/state/desk-code (0600, whole), a
      code used once and valid 60 s; GET /enter?code= sets a session cookie
      (HttpOnly, SameSite=Strict) and sends you to /desk; /desk and
      /desk/next are a test page, 403 without the cookie; GET /report?k=v is
      logged; DIR/state/stop-request makes it exit.
  fake_harness.py stop --home DIR        writes DIR/state/stop-request
  fake_harness.py autostart on|off --home DIR
  fake_harness.py autostart --home DIR   prints on or off
  fake_harness.py init --home DIR        writes DIR/config.ini ([apps] port:
      FAKE_PORT, or a free one)
  fake_harness.py config set KEY VALUE [KEY VALUE]... --home DIR
      keeps them in DIR/fake-settings.json; a value with "refuse" in it is
      refused as harness refuses (one line on stderr, exit 1, nothing kept);
      while `run` runs, says "harness is running: send /reload to use it."
  fake_harness.py config get KEY --home DIR
  fake_harness.py secret add NAME --stdin --home DIR
      reads the value from its input into DIR/fake-store/NAME (never logged)

Everything it does goes to DIR/fake.log, a line each.
"""
import http.server
import json
import os
import secrets
import struct
import sys
import threading
import time
import urllib.parse

CODE_LIFE = 60


def arg(argv, name):
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(name + "="):
            return a[len(name) + 1:]
    return None


def words(argv):
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in ("--home", "--port"):
            skip = True
            continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out


class Fake:
    def __init__(self, home):
        self.home = home
        self.state = os.path.join(home, "state")
        self.lock = threading.Lock()
        self.codes = {}  # code -> issued at
        self.sessions = set()
        self.port = 0

    def log(self, line):
        with self.lock:
            with open(os.path.join(self.home, "fake.log"), "a") as f:
                f.write(line + "\n")

    def write_whole(self, path, text, mode=0o600):
        tmp = path + ".tmp-" + secrets.token_hex(4)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)

    def watch(self, server):
        code_file = os.path.join(self.state, "desk-code")
        request = os.path.join(self.state, "open-request")
        stop = os.path.join(self.state, "stop-request")
        while True:
            time.sleep(0.1)
            if os.path.exists(stop):
                os.remove(stop)
                self.log("stop")
                threading.Thread(target=server.shutdown).start()
                return
            if os.path.exists(request):
                with open(request) as f:
                    said = f.read().strip()
                os.remove(request)
                code = secrets.token_urlsafe(24)
                with self.lock:
                    self.codes[code] = time.time()
                self.write_whole(code_file, code + "\n")
                self.log("code issued for " + said)
            # an unread code expires with its file
            with self.lock:
                old = [c for c, at in self.codes.items() if time.time() - at > CODE_LIFE]
                for c in old:
                    del self.codes[c]
            if old and os.path.exists(code_file):
                os.remove(code_file)
                self.log("code expired")


def page(path, port, other):
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>desk test</title></head>
<body style="background:#07070D;color:#E8E9F3;font:16px system-ui;padding:24px">
<h1>Test page {path}</h1>
<p><a id="next" href="/desk/next">Same address</a></p>
<p><a id="selfblank" href="/desk/next?via=blank" target="_blank">Same address, new window</a></p>
<p><a id="ext" href="https://example.com/">Elsewhere</a></p>
<p><a id="otherport" href="http://127.0.0.1:{other}/">Another port</a></p>
<p><a id="userinfo" href="http://127.0.0.1:{port}@example.com/">Look-alike</a></p>
<p><a id="blank" href="https://example.org/blank" target="_blank">Elsewhere, new window</a></p>
<p><a id="file" href="file:///etc/hosts">A file</a></p>
<script>
function post(m) {{ window.webkit.messageHandlers.harness.postMessage(m); }}
function report(k, v) {{ fetch("/report?" + encodeURIComponent(k) + "=" + encodeURIComponent(v)); }}
function click(id) {{ document.getElementById(id).click(); }}
report("page", location.pathname + location.search);
report("ua", navigator.userAgent);
if (location.pathname === "/desk") post({{badge: 3}});
try {{
  var gl = document.createElement("canvas").getContext("webgl2");
  report("webgl2", gl ? "yes" : "no");
}} catch (e) {{ report("webgl2", "error " + e.name); }}
var au = new Audio("/silence.wav");
au.play().then(function () {{ report("audio", "played"); }}, function (e) {{ report("audio", e.name); }});
try {{
  var u = new SpeechSynthesisUtterance("test");
  u.volume = 0;
  u.onstart = function () {{ report("speech", "started"); }};
  u.onerror = function (e) {{ report("speech", "error " + e.error); }};
  speechSynthesis.speak(u);
}} catch (e) {{ report("speech", "error " + e.name); }}
</script>
</body></html>
"""


def silence():
    rate, n = 8000, 4000
    data = b"\x00\x00" * n
    return (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " +
            struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(data)) + data)


def handler(fake, other):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, status, body=b"", kind="text/plain", headers=()):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def session(self):
            for part in (self.headers.get("Cookie") or "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == "desk" and v in fake.sessions:
                    return True
            return False

        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/alive":
                return self.send(200)
            if u.path == "/enter":
                code = (q.get("code") or [""])[0]
                with fake.lock:
                    at = fake.codes.pop(code, None)
                if at is None or time.time() - at > CODE_LIFE:
                    fake.log("enter refused")
                    return self.send(403, b"That code isn't valid.")
                s = secrets.token_urlsafe(24)
                fake.sessions.add(s)
                fake.log("enter ok " + code)
                return self.send(303, headers=[("Location", "/desk"),
                                               ("Set-Cookie", f"desk={s}; HttpOnly; SameSite=Strict; Path=/")])
            if u.path in ("/desk", "/desk/next"):
                if not self.session():
                    fake.log("page refused " + self.path)
                    return self.send(403, b"No session.")
                return self.send(200, page(self.path, fake.port, other).encode(), "text/html; charset=utf-8")
            if u.path == "/report":
                for k, vs in q.items():
                    fake.log(f"report {k}={vs[0]}")
                return self.send(204)
            if u.path == "/silence.wav":
                return self.send(200, silence(), "audio/wav")
            return self.send(404)

    return H


def config_port(home):
    try:
        with open(os.path.join(home, "config.ini")) as f:
            for line in f:
                k, _, v = line.partition("=")
                if k.strip() == "port":
                    return int(v.strip())
    except OSError:
        pass
    return None


def running(home):
    try:
        with open(os.path.join(home, "fake.pid")) as f:
            os.kill(int(f.read().strip()), 0)
        return True
    except (OSError, ValueError):
        return False


DEFAULTS = {"model.provider": "omnigate", "model.model": "claude-sonnet", "model.key": "omnigate",
            "model.memory_model": "claude-haiku", "model.worker_model": "claude-haiku"}


def settings(home):
    try:
        with open(os.path.join(home, "fake-settings.json")) as f:
            return json.load(f)
    except OSError:
        return {}


def run(home, argv):
    fake = Fake(home)
    os.makedirs(fake.state, exist_ok=True)
    port = arg(argv, "--port")
    if port is None:
        try:
            with open(os.path.join(fake.state, "desk.json")) as f:
                port = json.load(f)["port"]
        except OSError:
            port = config_port(home)
    fake.port = int(port)
    other = int(os.environ.get("FAKE_OTHER_PORT", "9"))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", fake.port), handler(fake, other))
    with open(os.path.join(home, "fake.pid"), "w") as f:
        f.write(str(os.getpid()))
    fake.write_whole(os.path.join(fake.state, "desk.json"), json.dumps({
        "binary": os.path.abspath(sys.argv[0]),
        "port": fake.port,
        "home": home,
        "version": "0.0.0-fake",
        "path": os.environ.get("PATH", ""),
    }))
    threading.Thread(target=fake.watch, args=(server,), daemon=True).start()
    fake.log(f"listening {fake.port}")
    server.serve_forever()
    fake.log("exited")


def main():
    argv = sys.argv[1:]
    home = arg(argv, "--home")
    w = words(argv)
    if not home or not w:
        print(__doc__, file=sys.stderr)
        return 2
    fake = Fake(home)
    if w[0] == "run":
        run(home, argv)
        return 0
    if w[0] == "stop":
        os.makedirs(fake.state, exist_ok=True)
        open(os.path.join(fake.state, "stop-request"), "w").close()
        fake.log("asked to stop")
        return 0
    if w[0] == "init":
        os.makedirs(fake.state, exist_ok=True)
        path = os.path.join(home, "config.ini")
        if not os.path.exists(path):
            port = os.environ.get("FAKE_PORT")
            if not port:
                import socket
                s = socket.socket()
                s.bind(("127.0.0.1", 0))
                port = s.getsockname()[1]
                s.close()
            with open(path, "w") as f:
                f.write("[model]\nprovider = omnigate\n[apps]\nport = %s\n" % port)
        fake.log("init")
        print("Data folder: " + home)
        return 0
    if w[0] == "config" and len(w) >= 3 and w[1] == "set":
        pairs = w[2:]
        if len(pairs) % 2:
            print("usage: harness config set SECTION.KEY VALUE", file=sys.stderr)
            return 2
        for i in range(0, len(pairs), 2):
            if "refuse" in pairs[i + 1]:
                print("Not changed: config.ini line 3: %s %s is refused by the stand-in" % (pairs[i], pairs[i + 1]), file=sys.stderr)
                fake.log("config refused")
                return 1
        cur = settings(home)
        for i in range(0, len(pairs), 2):
            cur[pairs[i]] = pairs[i + 1]
        fake.write_whole(os.path.join(home, "fake-settings.json"), json.dumps(cur))
        fake.log("config set " + " | ".join("%s=%s" % (pairs[i], pairs[i + 1]) for i in range(0, len(pairs), 2)))
        if running(home):
            print("harness is running: send /reload to use it.")
        return 0
    if w[0] == "config" and len(w) == 3 and w[1] == "get":
        print(settings(home).get(w[2], DEFAULTS.get(w[2], "")))
        return 0
    if w[0] == "secret" and len(w) == 3 and w[1] == "add" and "--stdin" in argv:
        value = sys.stdin.read()
        if value.endswith("\n"):
            value = value[:-1]
        if value.endswith("\r"):
            value = value[:-1]
        if len(value) < 8:
            print("values shorter than 8 characters can't be masked reliably; nothing stored", file=sys.stderr)
            return 1
        store = os.path.join(home, "fake-store")
        os.makedirs(store, exist_ok=True)
        fake.write_whole(os.path.join(store, w[2]), value)
        # the value itself is never logged
        fake.log("secret add %s (%d bytes)" % (w[2], len(value)))
        print("Stored %s in the stand-in's store." % w[2], file=sys.stderr)
        return 0
    if w[0] == "autostart":
        path = os.path.join(home, "fake-autostart")
        if len(w) > 1:
            if w[1] not in ("on", "off"):
                print("usage: autostart on|off", file=sys.stderr)
                return 2
            with open(path, "w") as f:
                f.write(w[1])
            fake.log("autostart " + w[1])
            return 0
        print(open(path).read().strip() if os.path.exists(path) else "off")
        return 0
    print("unknown command " + w[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
