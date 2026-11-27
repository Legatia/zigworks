#!/usr/bin/env python3
"""The Money page without harness, to look at it and to work on it.

    python3 harness/try-page.py PAYMCP PAY.ini [PORT]
    python3 harness/try-page.py PAYMCP --sim PAYMCP_SIM [PORT]

Serves harness/apps/money on 127.0.0.1 and answers the page's calls
(api/act) by asking a paymcp it starts, over MCP on stdio, as harness
would. With --sim it starts the stand-in billing provider too, with its
made-up business (with its four card disputes), and keeps the record in
a temporary folder.

This is not harness: there is no gate, nobody is asked, and nothing is
logged. It is for looking at the page. With a real pay file it reads the
real account (paymcp only reads) and a decision made on the page is
written into that pay file's record. STRIPE_KEY comes from the
environment, as paymcp wants it.
"""
import http.server
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "apps", "money")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8"}
# harness cuts a tool's answer at [limits] tool_output_bytes (16384)
CUT = 16384


def acts():
    """The tools app.ini lists: the only ones the page may call."""
    for raw in open(os.path.join(APP, "app.ini"), encoding="utf-8"):
        key, _, value = raw.partition("=")
        if key.strip() == "acts":
            return [x.strip() for x in value.split(",") if x.strip()]
    return []


class Mcp:
    def __init__(self, binary, pay, env):
        self.p = subprocess.Popen([binary, pay], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.lines = queue.Queue()
        threading.Thread(target=self.read_lines, daemon=True).start()
        self.i = 0
        self.lock = threading.Lock()
        if self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}}) is None:
            sys.exit("paymcp did not start: run 'paymcp check' on the pay file to see why")

    def read_lines(self):  # a thread, not select(): Windows can't select on pipes
        for line in iter(self.p.stdout.readline, b""):
            self.lines.put(line)
        self.lines.put(None)

    def rpc(self, method, params):
        with self.lock:
            self.i += 1
            want = self.i
            self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": want, "method": method, "params": params}) + "\n").encode())
            self.p.stdin.flush()
            end = time.time() + 120
            while True:
                try:
                    line = self.lines.get(timeout=max(0.0, end - time.time()))
                except queue.Empty:
                    return None
                if line is None:
                    self.lines.put(None)
                    return None
                m = json.loads(line)
                if m.get("id") == want:
                    return m

    def call(self, name, args):
        m = self.rpc("tools/call", {"name": name, "arguments": args})
        if m is None or "result" not in m:
            return "paymcp gave no answer"
        return m["result"]["content"][0]["text"]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[0].startswith("-"):
        sys.exit(__doc__)
    binary = args[0]
    env = dict(os.environ)
    procs = []
    tmp = None
    if args[1] == "--sim":
        if len(args) < 3:
            sys.exit(__doc__)
        sim_port = free_port()
        key = "rk_test_not_a_real_key"
        procs.append(subprocess.Popen([args[2], str(sim_port), key, "--disputes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        tmp = tempfile.mkdtemp(prefix="paymcp-page-")
        examples = os.path.join(HERE, "..", "examples")
        shutil.copy(os.path.join(examples, "who.csv"), tmp)
        shutil.copytree(os.path.join(examples, "payrun"), os.path.join(tmp, "payrun"))
        text = open(os.path.join(examples, "sim.ini"), encoding="utf-8").read().replace("8743", str(sim_port))
        text += "\n[payrun]\nsuppliers = payrun/suppliers.csv\n"
        pay = os.path.join(tmp, "pay.ini")
        open(pay, "w", encoding="utf-8").write(text)
        env["STRIPE_KEY"] = key
        rest = args[3:]
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", sim_port), 0.2).close()
                break
            except OSError:
                time.sleep(0.1)
    else:
        pay = args[1]
        rest = args[2:]
    port = int(rest[0]) if rest else 8744
    allowed = acts()
    mcp = Mcp(binary, pay, env)
    jobs = {}
    jobs_lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, status, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            # as harness serves an app: nothing from anywhere else, no inline script
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; form-action 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(data)

        def ours(self):
            host = self.headers.get("Host", "")
            return host in ("127.0.0.1:%d" % port, "localhost:%d" % port)

        def do_GET(self):
            if not self.ours():
                return self.send(403, '{"error":"another name for this machine"}')
            path = self.path.split("?")[0]
            if path.startswith("/api/act/"):
                with jobs_lock:
                    out = jobs.get(path[len("/api/act/"):])
                if out is None:
                    return self.send(404, '{"error":"no such act"}')
                return self.send(200, json.dumps({"id": int(path[len("/api/act/"):]), "state": "done", "output": out}))
            if path == "/api/info":
                return self.send(200, json.dumps({"name": "money"}))
            name = "index.html" if path == "/" else path.lstrip("/")
            full = os.path.join(APP, name)
            ext = os.path.splitext(name)[1]
            if "/" in name or "\\" in name or ext not in TYPES or not os.path.isfile(full):
                return self.send(404, '{"error":"not found"}')
            self.send(200, open(full, "rb").read(), TYPES[ext])

        def do_POST(self):
            if not self.ours() or self.path != "/api/act":
                return self.send(404, '{"error":"not found"}')
            try:
                call = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                tool = call["tool"]
            except (ValueError, KeyError):
                return self.send(400, '{"error":"the call is JSON: {\\"tool\\":..., \\"input\\":{...}}"}')
            if tool not in allowed:
                return self.send(403, '{"error":"this tool is not in the app\'s acts"}')
            out = mcp.call(tool.split("/", 1)[1], call.get("input") or {})
            raw = out.encode()
            if len(raw) > CUT:
                out = raw[:CUT].decode("utf-8", "ignore") + "\n[cut: the answer was longer than 16384 bytes]"
            with jobs_lock:
                job = str(len(jobs) + 1)
                jobs[job] = out
            self.send(200, json.dumps({"id": int(job), "state": "running"}))

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("The Money page: http://127.0.0.1:%d/  (no gate here: this is for looking at the page)" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for p in procs + [mcp.p]:
            p.kill()
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
