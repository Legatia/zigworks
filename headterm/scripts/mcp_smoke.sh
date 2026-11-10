#!/bin/sh
# End-to-end test of `headterm mcp`: pipes JSON-RPC requests through stdio
# and checks the replies.
# usage: scripts/mcp_smoke.sh [path/to/headterm]
set -eu

HT=${1:-zig-out/bin/headterm}
case $HT in /*) ;; *) HT=$(pwd)/$HT ;; esac

STATE=$(mktemp -d /tmp/headterm-mcp.XXXXXX)
unset XDG_RUNTIME_DIR
export TMPDIR=$STATE
trap '"$HT" kill mcpsmoke >/dev/null 2>&1 || true; rm -rf "$STATE"' EXIT

fail() {
    echo "FAIL: $*" >&2
    echo "--- replies:" >&2
    cat "$STATE/out" >&2
    exit 1
}

# All requests go in at once; the server handles them in order.
cat >"$STATE/in" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headterm_start","arguments":{"name":"mcpsmoke","command":["/bin/sh","-c","echo ready; read x; echo got:$x; read y; echo bye:$y"],"cols":40,"rows":8}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"mcpsmoke","keys":["hello","<Enter>"],"then_wait":{"text":"got:hello","timeout_ms":5000}}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"headterm_screen","arguments":{"name":"mcpsmoke","diff":true}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"mcpsmoke","keys":["world","<Enter>"],"then_wait":{"exit":true,"timeout_ms":5000}}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"headterm_wait","arguments":{"name":"mcpsmoke","text":"never-appears","timeout_ms":200}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"headterm_list","arguments":{}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"headterm_kill","arguments":{"name":"mcpsmoke"}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"headterm_screen","arguments":{"name":"mcpsmoke"}}}
{"jsonrpc":"2.0","id":11,"method":"resources/list"}
{"jsonrpc":"2.0","id":12,"method":"ping"}
this is not json
EOF

"$HT" mcp <"$STATE/in" >"$STATE/out" 2>"$STATE/err" || fail "mcp exited with $?"

reply() { grep "\"id\":$1," "$STATE/out" || fail "no reply for id $1"; }

check() { # check <description> <id> <pattern>...
    desc=$1
    r=$(reply "$2")
    shift 2
    for pat in "$@"; do
        printf '%s' "$r" | grep -qF -- "$pat" || fail "$desc: missing $pat"
    done
    echo "ok - $desc"
}

lines=$(wc -l <"$STATE/out" | tr -d ' ')
[ "$lines" -eq 13 ] || fail "expected 13 replies (12 requests + parse error), got $lines"
grep -qv '^{"jsonrpc":"2.0",' "$STATE/out" && fail "stdout has a line that is not a JSON-RPC message"
echo "ok - 13 replies, one JSON-RPC message per line, nothing else on stdout"

check "initialize" 1 '"protocolVersion":"2025-06-18"' '"serverInfo":{"name":"headterm"'
check "tools/list" 2 '"headterm_start"' '"headterm_send"' '"headterm_screen"' '"headterm_wait"' '"headterm_kill"' '"headterm_list"' '"headterm_resize"'
check "start returns first screen" 3 'started mcpsmoke pid=' 'ready' '"isError":false'
check "send with then_wait returns result" 4 'got:hello' 'wait=ok(text)' '"isError":false'
check "screen diff after wait is empty" 5 'changed=0' '"isError":false'
check "send then wait for exit" 6 'bye:world' 'exited=0' '"isError":false'
check "wait timeout is a tool error" 7 'wait=failed(exited)' '"isError":true'
check "list" 8 'mcpsmoke' '/bin/sh -c' '"isError":false'
check "kill" 9 'killed mcpsmoke' '"isError":false'
check "screen after kill" 10 "no session named 'mcpsmoke'" '"isError":true'
check "unknown method" 11 '"code":-32601'
check "ping" 12 '"result":{}'
grep -q '"id":null,"error":{"code":-32700' "$STATE/out" || fail "parse error reply"
echo "ok - parse error"

echo "mcp smoke: all passed"
