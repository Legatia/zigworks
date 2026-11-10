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
trap '"$HT" kill mcpsmoke >/dev/null 2>&1 || true; "$HT" kill mcpsty >/dev/null 2>&1 || true; rm -rf "$STATE"' EXIT

fail() {
    echo "FAIL: $*" >&2
    echo "--- replies:" >&2
    cat "$STATE/out" >&2
    exit 1
}

# All requests go in at once; the server handles them in order.
cat >"$STATE/in" <<'REQUESTS'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headterm_start","arguments":{"name":"mcpsmoke","command":["/bin/sh","-c","echo ready; read x; echo got:$x; read y; echo bye:$y"],"cols":40,"rows":8}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"mcpsmoke","keys":["--literal","<Enter>"],"then_wait":{"text":"got:","timeout_ms":5000}}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"headterm_screen","arguments":{"name":"mcpsmoke","diff":true}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"mcpsmoke","keys":["w<o>rld"],"literal":true}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"headterm_send","arguments":{"name":"mcpsmoke","keys":["<Enter>"],"then_wait":{"exit":true,"timeout_ms":5000}}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"headterm_wait","arguments":{"name":"mcpsmoke","text":"never-appears","timeout_ms":200}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"headterm_list","arguments":{}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"headterm_kill","arguments":{"name":"mcpsmoke"}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"headterm_screen","arguments":{"name":"mcpsmoke"}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"headterm_start","arguments":{"name":"mcpsty","command":["/bin/sh","-c","printf '  Open\\r\\n\\033[7m  Save  \\033[m\\r\\n\\033[1;31mError\\033[m'; sleep 30"],"cols":20,"rows":4,"styles":true}}}
{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"headterm_kill","arguments":{"name":"mcpsty"}}}
{"jsonrpc":"2.0","id":14,"method":"resources/list"}
{"jsonrpc":"2.0","id":15,"method":"ping"}
this is not json
REQUESTS

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
[ "$lines" -eq 16 ] || fail "expected 16 replies (15 requests + parse error), got $lines"
grep -qv '^{"jsonrpc":"2.0",' "$STATE/out" && fail "stdout has a line that is not a JSON-RPC message"
echo "ok - 16 replies, one JSON-RPC message per line, nothing else on stdout"

check "initialize" 1 '"protocolVersion":"2025-06-18"' '"serverInfo":{"name":"headterm"'
check "tools/list" 2 '"headterm_start"' '"headterm_send"' '"headterm_screen"' '"headterm_wait"' '"headterm_kill"' '"headterm_list"' '"headterm_resize"' '"esc_delay_ms"'
check "start returns first screen" 3 'started mcpsmoke pid=' 'ready' '"isError":false'
check "keys are never options" 4 'got:--literal' 'wait=ok(text)' '"isError":false'
check "screen diff after wait is empty" 5 'changed=0' '"isError":false'
check "send literal" 6 '"text":"sent"' '"isError":false'
check "send then wait for exit" 7 'bye:w<o>rld' 'exited=0' '"isError":false'
check "wait timeout is a tool error" 8 'wait=failed(exited)' '"isError":true'
check "list" 9 'mcpsmoke' '/bin/sh -c' '"isError":false'
check "kill" 10 'killed mcpsmoke' '"isError":false'
check "screen after kill" 11 "no session named 'mcpsmoke'" '"isError":true'
check "start with styles" 12 '[0-8 inverse \"  Save\"]' '[0-5 bold fg=red \"Error\"]' '"isError":false'
check "kill styled session" 13 'killed mcpsty'
check "unknown method" 14 '"code":-32601'
check "ping" 15 '"result":{}'
grep -q '"id":null,"error":{"code":-32700' "$STATE/out" || fail "parse error reply"
echo "ok - parse error"

# Cancellation: a 30 s wait is cancelled after about 1 s. The cancelled
# request gets no reply; requests sent meanwhile are answered afterwards.
start=$(date +%s)
{
    echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"headterm_start","arguments":{"name":"mcpsmoke","command":["sleep","60"]}}}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"headterm_wait","arguments":{"name":"mcpsmoke","text":"never","timeout_ms":30000}}}'
    sleep 1
    echo '{"jsonrpc":"2.0","id":3,"method":"ping"}'
    echo '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"test"}}'
    echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headterm_kill","arguments":{"name":"mcpsmoke"}}}'
    sleep 1
} | "$HT" mcp >"$STATE/out" 2>"$STATE/err" || fail "mcp exited with $?"
elapsed=$(($(date +%s) - start))
[ "$elapsed" -lt 10 ] || fail "cancelled wait still blocked for ${elapsed}s"
grep -q '"id":2,' "$STATE/out" && fail "cancelled request got a reply"
check "ping sent during the wait is answered" 3 '"result":{}'
check "kill after the cancelled wait" 4 'killed mcpsmoke' '"isError":false'
echo "ok - cancelled wait returned in ${elapsed}s with no reply"

echo "mcp smoke: all passed"
