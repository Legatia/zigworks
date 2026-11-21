#!/bin/sh
# End to end: the real harness binary against harness-fake (omnigate,
# Telegram, feeds, search). No network, no real keys.
# Usage: smoke.sh HARNESS HARNESS_FAKE
set -u
H=$1
# absolute: MCP servers start in the workspace folder
# (pwd -W under Git for Windows: D:/..., a path the Windows program can open)
F=$(cd "$(dirname "$2")" && { pwd -W 2>/dev/null || pwd; })/$(basename "$2")
T=$(mktemp -d)
FPID=""
RPID=""
cleanup() {
	[ -n "$RPID" ] && kill "$RPID" 2>/dev/null
	[ -n "$FPID" ] && kill "$FPID" 2>/dev/null && wait "$FPID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
export HARNESS_HOME="$T/home" HARNESS_STORE="$T/secrets"
S="$T/script"
mkdir -p "$S"
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=1 ;; *) windows=0 ;; esac

n=0
fail=0
check() {
	n=$((n + 1))
	if eval "$2"; then echo "ok $n - $1"; else
		echo "not ok $n - $1"
		fail=1
	fi
}
# wait_for FILE PATTERN [SECONDS]: grep -F until it matches
wait_for() {
	i=0
	while [ $i -lt $((${3:-10} * 10)) ]; do
		grep -qF -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}
inbox_n=0
inbox() {
	inbox_n=$((inbox_n + 1))
	printf '%s' "$1" >"$S/telegram/in/$(printf %03d $inbox_n).json"
}
say() { inbox "{\"message\":{\"from\":{\"id\":42},\"chat\":{\"id\":42},\"text\":\"$1\"}}"; }
model() { printf '%s' "$2" >"$S/model/$(printf %03d "$1").json"; }
text_reply() { printf '{"content":[{"type":"text","text":"%s"}],"stop_reason":"end_turn"}' "$1"; }
tool_reply() { printf '{"content":[{"type":"tool_use","id":"%s","name":"shell","input":{"command":"%s"}}],"stop_reason":"tool_use"}' "$1" "$2"; }
sha() { if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum; else printf '%s' "$1" | shasum -a 256; fi | cut -c1-32; }

"$F" --dir "$S" >"$T/fake.out" &
FPID=$!
wait_for "$T/fake.out" "port " 5 || { echo "harness-fake did not start"; exit 1; }
PORT=$(sed -n 's/^port //p' "$T/fake.out")
URL="http://127.0.0.1:$PORT"

check "init writes the data folder" '"$H" init >/dev/null && [ -f "$HARNESS_HOME/config.ini" ] && [ -d "$HARNESS_HOME/workspace" ]'
cat >"$HARNESS_HOME/config.ini" <<EOF
[model]
url = $URL
[search]
url = $URL
[chat]
api = $URL
[limits]
approval_seconds = 30
EOF
printf 'allow shell sleep *\nallow mcp fake/echo *\n' >"$HARNESS_HOME/rules"
printf '[fake]\ncommand = "%s" --mcp\n' "$F" >"$HARNESS_HOME/mcp.ini"
chmod 600 "$HARNESS_HOME/config.ini" "$HARNESS_HOME/rules"
printf 'og-smoke-key-123\n' | "$H" secret add omnigate --stdin 2>/dev/null
printf '111:telegram-smoke-token\n' | "$H" secret add telegram --stdin 2>/dev/null
printf 'brave-smoke-key-1\n' | "$H" secret add search --stdin 2>/dev/null
check "secrets stored" '[ "$("$H" secret list | grep -c ": stored")" = 3 ]'
check "a short secret is refused" '! printf "short\n" | "$H" secret add x --stdin 2>/dev/null'
printf 'smoke-login-pass-1\n\n' | "$H" login add bot --site localhost --username agent-bot --stdin 2>/dev/null
check "a login is added and listed" '"$H" login list | grep -qF "bot: localhost, username agent-bot, password yes, TOTP no, passkeys 0"'
printf 'leftover-pass-1\n' | "$H" secret add login-zed-password --stdin 2>/dev/null
check "a login is not added over secrets left from an old one" '! printf "\n\n" | "$H" login add zed --site example.com --stdin 2>"$T/zed.err" && grep -qF "harness login rm zed" "$T/zed.err" && ! grep -qF "[zed]" "$HARNESS_HOME/logins.ini"'

# a scheduled task, run by hand before the service starts
printf '[check]\nevery = 5m\ndo = Check the price.\n' >"$HARNESS_HOME/tasks.ini"
model 1 "$(text_reply 'Price is flat.')"
check "task run prints the answer" '"$H" task run check 2>/dev/null | grep -qF "[check] Price is flat."'
check "the model got the omnigate key" 'grep -qF "\"x-api-key\":\"og-smoke-key-123\"" "$S/requests/001.json"'
: >"$HARNESS_HOME/tasks.ini"

# a brief source with one item sent before
cat >"$S/pages/z.xml" <<'EOF'
<rss><channel>
<item><title>Old item</title><link>https://z.org/old</link></item>
<item><title>New item</title><link>https://z.org/new</link></item>
</channel></rss>
EOF
printf '[morning]\nat = 23:59\ntopic = Zig | %s/page/z.xml\n' "$URL" >"$HARNESS_HOME/briefs.ini"
mkdir -p "$HARNESS_HOME/state"
printf '%s\t%s\n' "$(sha https://z.org/old)" "$(date +%s)" >"$HARNESS_HOME/state/seen"

"$H" run >"$T/run.out" 2>&1 &
RPID=$!
wait_for "$T/run.out" "running on" 5
check "a second instance is refused" '! "$H" chat </dev/null 2>"$T/second.err" && grep -qF "already running" "$T/second.err"'
check "health says running" '"$H" health >/dev/null'

CODE=$("$H" pair | sed -n 's|^/pair ||p')
inbox "{\"message\":{\"from\":{\"id\":7},\"chat\":{\"id\":7},\"text\":\"hello\"}}"
say "/pair $CODE"
OUT="$S/telegram/out.jsonl"
check "pairing answers the owner" 'wait_for "$OUT" "Paired."'
check "a stranger is dropped and logged" 'grep -qF "\"from\":7" "$HARNESS_HOME/log/actions.jsonl"'

model 2 "$(tool_reply tu_1 'echo smoke-ran')"
model 3 "$(text_reply 'done: smoke-ran')"
say "run the echo"
check "the shell call asks for approval" 'wait_for "$OUT" "a1:day"'
inbox '{"callback_query":{"id":"cb1","from":{"id":42},"message":{"message_id":1,"chat":{"id":42}},"data":"a1:day"}}'
check "after approval the answer arrives" 'wait_for "$OUT" "done: smoke-ran"'
check "the command ran" 'grep -qF "smoke-ran" "$S/requests/003.json"'

model 4 "$(tool_reply tu_2 'echo smoke-ran')"
model 5 "$(text_reply 'again done')"
say "again"
check "the 24 h grant skips asking" 'wait_for "$OUT" "again done" && [ "$(grep -c "inline_keyboard\":\[\[" "$OUT")" = 1 ]'

model 6 "$(text_reply 'Zig: New item (https://z.org/new)')"
say "/brief"
check "the brief has the new item" 'wait_for "$OUT" "Zig: New item (https://z.org/new)"'
check "the seen item was not sent to the model" '! grep -qF "z.org/old" "$S/requests/006.json"'

model 7 '{"status":402}'
say "hello"
check "a spent budget is reported" 'wait_for "$OUT" "Model budget used up."'

if [ $windows = 0 ]; then
	model 8 "$(tool_reply tu_3 'sleep 30')"
	model 9 "$(text_reply 'never')"
	say "sleep"
	wait_for "$S/requests/008.json" "sleep" 5
	sleep 0.5
	say "/stop"
	check "stop ends a running command" 'wait_for "$OUT" "Stopped everything that was running." 10'
	check "no model call after stop" '[ ! -f "$S/requests/009.json" ]'
fi

say "/remember I prefer short briefs"
say "/memory"
check "a remembered item is listed" 'wait_for "$OUT" "I prefer short briefs"'

# the next model script number: on POSIX the stop check used 8, and 9 (never asked for) is free
if [ $windows = 0 ]; then m=9; else m=8; fi
say "/status"
check "the MCP server started" 'wait_for "$OUT" "MCP: fake (3 tools)"'
model $m '{"content":[{"type":"tool_use","id":"tu_m","name":"fake__echo","input":{"text":"env"}}],"stop_reason":"tool_use"}'
model $((m + 1)) "$(text_reply 'mcp done')"
say "use the echo server"
# the server reports its HOME: the real one, not the default before start-up finished
# (on Windows that is USERPROFILE, with its backslashes doubled in the JSON)
if [ $windows = 0 ]; then home_json=$HOME; else home_json=$(printf %s "$USERPROFILE" | sed 's/\\/\\\\/g'); fi
check "an MCP tool runs through the gate with the real HOME" 'wait_for "$OUT" "mcp done" && grep -qF "home=$home_json" "$S/requests/$(printf %03d $((m + 1))).json"'
m=$((m + 2))
model $m '{"content":[{"type":"tool_use","id":"tu_d","name":"delegate","input":{"tasks":[{"task":"part one"},{"task":"part two"}]}}],"stop_reason":"tool_use"}'
model $((m + 1)) "$(text_reply 'helper said hi')"
model $((m + 2)) "$(text_reply 'helper said hi')"
model $((m + 3)) "$(text_reply 'delegated ok')"
say "split this"
check "helpers answer the agent" 'wait_for "$OUT" "delegated ok" && [ "$(grep -o "helper said hi" "$S/requests/$(printf %03d $((m + 3))).json" | wc -l | tr -d " ")" = 2 ]'

kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
RPID=""
check "the log chain verifies" '"$H" log verify | grep -qF "chain intact"'
check "no secret value in the log" '! grep -qE "og-smoke-key-123|telegram-smoke-token|brave-smoke-key|smoke-login-pass" "$HARNESS_HOME/log/actions.jsonl"'
check "a login is removed with its secrets" '"$H" login rm bot >/dev/null && "$H" login list | grep -qF "No logins." && [ ! -e "$HARNESS_STORE/login-bot-password" ] && ! grep -qF "[bot]" "$HARNESS_HOME/logins.ini"'
# Windows keeps a killed instance's lock for 90 s (no pid check there)
if [ $windows = 0 ]; then
	check "memory list works offline" '"$H" memory list 2>/dev/null | grep -qF "I prefer short briefs"'
fi

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- run output"; cat "$T/run.out"
	echo "--- outbox"; cat "$OUT" 2>/dev/null
	exit 1
fi
