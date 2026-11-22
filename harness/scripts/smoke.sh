#!/bin/sh
# End to end: the real harness binary against harness-fake (omnigate and
# other model providers, Telegram, feeds, search). No network, no real keys.
# Usage: smoke.sh HARNESS HARNESS_FAKE
set -u
H=$1
# absolute: MCP servers start in a folder of their own (state/mcp/NAME)
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
# in_topic THREAD TEXT: the owner writes in topic THREAD ("House search") of
# their chat with the bot
in_topic() { inbox "{\"message\":{\"message_id\":$((inbox_n + 1000)),\"from\":{\"id\":42},\"chat\":{\"id\":42,\"type\":\"private\"},\"message_thread_id\":$1,\"is_topic_message\":true,\"reply_to_message\":{\"message_id\":1,\"forum_topic_created\":{\"name\":\"House search\"}},\"text\":\"$2\"}}"; }
# what the bot sent, a line per call with the message id it got
OUT="$S/telegram/out.jsonl"
# button once|day|deny: "MESSAGE_ID DATA" of that button under the last question
button() {
	grep -F '"inline_keyboard":[[' "$OUT" 2>/dev/null | tail -n 1 |
		sed -n 's/^{"method":"sendMessage","message_id":\([0-9]*\),.*"callback_data":"\([^"]*:'"$1"'\)".*/\1 \2/p'
}
# press once|day|deny [MESSAGE_ID]: the owner presses that button of the last
# question, in the message it is in unless another is given
press() {
	b=$(button "$1")
	[ -n "$b" ] || return 1
	inbox "{\"callback_query\":{\"id\":\"cb$inbox_n\",\"from\":{\"id\":42},\"message\":{\"message_id\":${2:-${b%% *}},\"chat\":{\"id\":42}},\"data\":\"${b#* }\"}}"
}
model() { printf '%s' "$2" >"$S/model/$(printf %03d "$1").json"; }
# the model's requests are answered in order: reply ANSWER is the answer to
# the next one, req [N] the file of request N (default: the last replied to)
mn=0
reply() {
	mn=$((mn + 1))
	model $mn "$1"
}
req() { printf '%s/requests/%03d.json' "$S" "${1:-$mn}"; }
text_reply() { printf '{"content":[{"type":"text","text":"%s"}],"stop_reason":"end_turn"}' "$1"; }
tool_reply() { printf '{"content":[{"type":"tool_use","id":"%s","name":"shell","input":{"command":"%s"}}],"stop_reason":"tool_use"}' "$1" "$2"; }
# call_reply ID TOOL INPUT_JSON: the model calls any tool
call_reply() { printf '{"content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}],"stop_reason":"tool_use"}' "$1" "$2" "$3"; }
# result N ID TEXT: request N carries the result of call ID, starting with TEXT
result() { grep -qF "\"tool_use_id\":\"$2\",\"content\":\"$3" "$(req "$1")"; }
# the questions asked so far (messages with buttons), and the last one
asked() {
	q=$(grep -c '"inline_keyboard":\[\[' "$OUT" 2>/dev/null)
	echo "${q:-0}"
}
last_question() { grep -F '"inline_keyboard":[[' "$OUT" | tail -n 1; }
# wait_asked N: until N questions have been asked
wait_asked() {
	i=0
	while [ $i -lt 100 ]; do
		[ "$(asked)" -ge "$1" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}
sha() { if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum; else printf '%s' "$1" | shasum -a 256; fi | cut -c1-32; }

"$F" --dir "$S" >"$T/fake.out" &
FPID=$!
wait_for "$T/fake.out" "port " 5 || { echo "harness-fake did not start"; exit 1; }
PORT=$(sed -n 's/^port //p' "$T/fake.out")
URL="http://127.0.0.1:$PORT"

check "version prints the version" '"$H" version >"$T/version.out" && grep -qxE "harness [0-9]+[.][0-9]+[.][0-9]+" "$T/version.out"'
check "help lists the commands" '"$H" help >"$T/help.out" && grep -qF "secret add NAME [--stdin]" "$T/help.out" && grep -qF "task run NAME" "$T/help.out"'
check "init writes the data folder" '"$H" init >/dev/null && [ -f "$HARNESS_HOME/config.ini" ] && [ -d "$HARNESS_HOME/workspace" ]'
check "health fails when nothing runs" '! "$H" health >"$T/health.out" && grep -qxF "not running" "$T/health.out"'
# init's config.ini has no omnigate url, and no key is stored yet
check "a command says when no omnigate key or url is set" '"$H" memory list >/dev/null 2>"$T/notes.err" && grep -qF "no omnigate key stored" "$T/notes.err" && grep -qF "no omnigate url" "$T/notes.err"'
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
# shop: the same server, its echo a money tool capped at 10 a call
printf '[fake]\ncommand = "%s" --mcp\n[shop]\ncommand = "%s" --mcp\nmoney = echo\namount = amount\nmax_per_call = 10\n' "$F" "$F" >"$HARNESS_HOME/mcp.ini"
chmod 600 "$HARNESS_HOME/config.ini" "$HARNESS_HOME/rules"
printf 'og-smoke-key-123\n' | "$H" secret add omnigate --stdin 2>/dev/null
printf '111:telegram-smoke-token\n' | "$H" secret add telegram --stdin 2>/dev/null
printf 'brave-smoke-key-1\n' | "$H" secret add search --stdin 2>/dev/null
check "secrets stored" '[ "$("$H" secret list | grep -c ": stored")" = 3 ]'
check "a short secret is refused" '! printf "short\n" | "$H" secret add x --stdin 2>/dev/null'
printf 'spare-value-123\n' | "$H" secret add spare --stdin 2>/dev/null
check "a secret is removed" '[ -e "$HARNESS_STORE/spare" ] && "$H" secret rm spare >"$T/rm.out" && grep -qxF "Removed." "$T/rm.out" && [ ! -e "$HARNESS_STORE/spare" ] && "$H" secret rm spare | grep -qxF "Nothing stored under that name."'
check "a value piped without --stdin is refused" '! printf "piped-value-123\n" | "$H" secret add piped 2>"$T/piped.err" && grep -qF -- "--stdin" "$T/piped.err" && [ ! -e "$HARNESS_STORE/piped" ]'
printf 'smoke-login-pass-1\n\n' | "$H" login add bot --site localhost --username agent-bot --stdin 2>/dev/null
check "a login is added and listed" '"$H" login list | grep -qF "bot: localhost, username agent-bot, password yes, TOTP no, passkeys 0"'
printf 'leftover-pass-1\n' | "$H" secret add login-zed-password --stdin 2>/dev/null
check "a login is not added over secrets left from an old one" '! printf "\n\n" | "$H" login add zed --site example.com --stdin 2>"$T/zed.err" && grep -qF "harness login rm zed" "$T/zed.err" && ! grep -qF "[zed]" "$HARNESS_HOME/logins.ini"'

# a scheduled task, run by hand before the service starts
printf '[check]\nevery = 5m\ndo = Check the price.\n' >"$HARNESS_HOME/tasks.ini"
reply "$(text_reply 'Price is flat.')"
check "task run prints the answer" '"$H" task run check 2>/dev/null | grep -qF "[check] Price is flat."'
check "the model got the omnigate key" 'grep -qF "\"x-api-key\":\"og-smoke-key-123\"" "$(req)"'
# another provider: an OpenAI-format gateway that takes a bearer key
printf 'sk-local-smoke-key-1\n' | "$H" secret add local --stdin 2>/dev/null
cp "$HARNESS_HOME/config.ini" "$T/config.ini.saved"
cat >"$HARNESS_HOME/config.ini" <<EOF
[model]
url = $URL
model = local:gpt-smoke
[provider local]
api = openai
url = $URL/v1
auth = bearer
[search]
url = $URL
[chat]
api = $URL
EOF
check "secret list names the key of a provider in use" '"$H" secret list | grep -qxF "local (local key): stored"'
reply '{"choices":[{"message":{"role":"assistant","content":"Price is up."},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}'
check "a task runs through an OpenAI-format provider with its bearer key" '"$H" task run check 2>/dev/null | grep -qF "[check] Price is up." && grep -qF "\"target\":\"/v1/chat/completions\"" "$(req)" && grep -qF "\"Authorization\":\"Bearer sk-local-smoke-key-1\"" "$(req)" && grep -qF "\"provider\":\"local\"" "$HARNESS_HOME/log/actions.jsonl" && ! grep -qF "sk-local-smoke-key-1" "$HARNESS_HOME/log/actions.jsonl"'
cp "$T/config.ini.saved" "$HARNESS_HOME/config.ini"
: >"$HARNESS_HOME/tasks.ini"

# a brief source with one item sent before
cat >"$S/pages/z.xml" <<'EOF'
<rss><channel>
<item><title>Old item</title><link>https://z.org/old</link></item>
<item><title>New item</title><link>https://z.org/new</link></item>
</channel></rss>
EOF
printf '<rss><channel><item><title>Fresh item</title><link>https://y.org/fresh</link></item></channel></rss>\n' >"$S/pages/y.xml"
printf '[morning]\nat = 23:59\ntopic = Zig | %s/page/z.xml\n[evening]\nat = 23:59\ntopic = Zag | %s/page/y.xml\n' "$URL" "$URL" >"$HARNESS_HOME/briefs.ini"
mkdir -p "$HARNESS_HOME/state"
printf '%s\t%s\n' "$(sha https://z.org/old)" "$(date +%s)" >"$HARNESS_HOME/state/seen"
reply "$(text_reply 'Zag: Fresh item (https://y.org/fresh)')"
check "harness brief collects and prints a brief" '"$H" brief evening 2>/dev/null | grep -qF "Zag: Fresh item (https://y.org/fresh)" && grep -qF "y.org/fresh" "$(req)"'

"$H" run >"$T/run.out" 2>&1 &
RPID=$!
wait_for "$T/run.out" "running on" 5
check "a second instance is refused" '! "$H" chat </dev/null 2>"$T/second.err" && grep -qF "already running" "$T/second.err"'
check "health says running" '"$H" health >/dev/null'

CODE=$("$H" pair | sed -n 's|^/pair ||p')
inbox "{\"message\":{\"from\":{\"id\":7},\"chat\":{\"id\":7},\"text\":\"hello\"}}"
say "/pair $CODE"
check "pairing answers the owner" 'wait_for "$OUT" "Paired."'
check "a stranger is dropped and logged" 'grep -qF "\"from\":7" "$HARNESS_HOME/log/actions.jsonl"'

reply "$(tool_reply tu_1 'echo smoke-ran')"
reply "$(text_reply 'done: smoke-ran')"
say "run the echo"
# the buttons carry the question's number and this start's nonce
check "the shell call asks for approval" 'wait_for "$OUT" "\"inline_keyboard\":[[" && button day | grep -qE "^[0-9]+ a[0-9]+-[0-9a-f]{16}:day$"'
b=$(button day)
press day $((${b%% *} + 1))
check "a press in another message answers nothing" 'wait_for "$OUT" "That button is out of date" && [ ! -f "$(req)" ]'
press day
check "after approval the answer arrives" 'wait_for "$OUT" "done: smoke-ran"'
check "the command ran" 'grep -qF "smoke-ran" "$(req)"'

reply "$(tool_reply tu_2 'echo smoke-ran')"
reply "$(text_reply 'again done')"
say "again"
check "the 24 h grant skips asking" 'wait_for "$OUT" "again done" && [ "$(grep -c "inline_keyboard\":\[\[" "$OUT")" = 1 ]'

reply "$(text_reply 'Zig: New item (https://z.org/new)')"
say "/brief"
check "the brief has the new item" 'wait_for "$OUT" "Zig: New item (https://z.org/new)"'
check "the seen item was not sent to the model" '! grep -qF "z.org/old" "$(req)"'

reply '{"status":402}'
say "hello"
check "a spent budget is reported" 'wait_for "$OUT" "Model budget used up."'

if [ $windows = 0 ]; then
	reply "$(tool_reply tu_3 'sleep 30')"
	# never asked for: the next reply takes its number
	model $((mn + 1)) "$(text_reply 'never')"
	say "sleep"
	wait_for "$(req)" "sleep" 5
	sleep 0.5
	say "/stop"
	check "stop ends a running command" 'wait_for "$OUT" "Stopped everything that was running." 10'
	check "no model call after stop" '[ ! -f "$(req $((mn + 1)))" ]'
fi

say "/remember I prefer short briefs"
say "/memory"
check "a remembered item is listed" 'wait_for "$OUT" "I prefer short briefs"'

say "/status"
check "the MCP server started" 'wait_for "$OUT" "MCP: fake (3 tools)"'
reply '{"content":[{"type":"tool_use","id":"tu_m","name":"fake__echo","input":{"text":"env"}}],"stop_reason":"tool_use"}'
reply "$(text_reply 'mcp done')"
say "use the echo server"
# the server reports its HOME: the real one, not the default before start-up finished
# (on Windows that is USERPROFILE, with its backslashes doubled in the JSON)
if [ $windows = 0 ]; then home_json=$HOME; else home_json=$(printf %s "$USERPROFILE" | sed 's/\\/\\\\/g'); fi
check "an MCP tool runs through the gate with the real HOME" 'wait_for "$OUT" "mcp done" && grep -qF "home=$home_json" "$(req)"'
reply '{"content":[{"type":"tool_use","id":"tu_d","name":"delegate","input":{"tasks":[{"task":"part one"},{"task":"part two"}]}}],"stop_reason":"tool_use"}'
reply "$(text_reply 'helper said hi')"
reply "$(text_reply 'helper said hi')"
reply "$(text_reply 'delegated ok')"
say "split this"
check "helpers answer the agent" 'wait_for "$OUT" "delegated ok" && [ "$(grep -o "helper said hi" "$(req)" | wc -l | tr -d " ")" = 2 ]'

# an MCP tool no rule allows asks by default: once it runs, denied it doesn't
reply "$(call_reply tu_s1 fake__sleep '{"ms":1}')"
reply "$(call_reply tu_s2 fake__sleep '{"ms":2}')"
reply "$(text_reply 'slept once')"
say "sleep twice"
check "an MCP tool with no rule asks" 'wait_asked 2 && last_question | grep -qF "fake__sleep: fake/sleep" && [ -n "$(button day)" ]'
press once
wait_asked 3
press deny
check "allowed once it runs, denied it does not" 'wait_for "$OUT" "slept once" && result $((mn - 1)) tu_s1 slept && result $mn tu_s2 "refused by the gate: denied by the owner"'
# "Allow 24 h" covers the tool whatever its input
reply "$(call_reply tu_s3 fake__sleep '{"ms":3}')"
reply "$(call_reply tu_s4 fake__sleep '{"ms":4}')"
reply "$(text_reply 'slept on the grant')"
say "sleep on"
wait_asked 4
press day
check "an Allow 24 h grant covers the next call" 'wait_for "$OUT" "slept on the grant" && [ "$(asked)" = 4 ] && result $mn tu_s4 slept'

# a money tool: asked every time, never for 24 h, capped, not made in a dry run
reply "$(call_reply tu_o1 shop__echo '{"text":"order one","amount":5}')"
reply "$(call_reply tu_o2 shop__echo '{"text":"order two","amount":5}')"
reply "$(text_reply 'two orders placed')"
say "buy twice"
check "a money call asks with no Allow 24 h" 'wait_asked 5 && last_question | grep -qF "Dry run is off: this call is made." && [ -n "$(button once)" ] && [ -z "$(button day)" ]'
press once
wait_asked 6
press once
check "a money call is asked every time" 'wait_for "$OUT" "two orders placed" && [ "$(asked)" = 6 ] && result $((mn - 1)) tu_o1 "order one" && result $mn tu_o2 "order two"'
reply "$(call_reply tu_o3 shop__echo '{"text":"big order","amount":50}')"
reply "$(text_reply 'too big')"
say "buy big"
check "a money call over the cap is refused before asking" 'wait_for "$OUT" "too big" && [ "$(asked)" = 6 ] && result $mn tu_o3 "refused by the gate: 50 is over the cap of 10 per call"'
say "/dryrun on"
wait_for "$OUT" "Dry run is on: tools that move money are not called"
reply "$(call_reply tu_o4 shop__echo '{"text":"order four","amount":5}')"
reply "$(text_reply 'dry order done')"
say "buy in a dry run"
wait_asked 7
press once
check "with /dryrun on an approved money call is not made" 'wait_for "$OUT" "dry order done" && last_question | grep -qF "Dry run is on: this call is not made." && result $mn tu_o4 "dry run: would call shop/echo"'
say "/dryrun off"
wait_for "$OUT" "Dry run is off: approved money calls are made."

# folders.ini: notes written by the agent itself, not its helpers, and
# snapshotted around the runs that change it
printf '[notes]\nwrite = agent:main\nsnapshots = on\n' >"$HARNESS_HOME/folders.ini"
chmod 600 "$HARNESS_HOME/folders.ini"
say "/reload"
check "folders.ini applies after /reload" 'wait_for "$OUT" "Settings reloaded."'
reply "$(call_reply tu_f1 delegate '{"tasks":[{"task":"write the note","tools":["write_file"]}]}')"
reply "$(call_reply tu_f2 write_file '{"path":"notes/h.md","content":"from the helper"}')"
reply "$(text_reply 'the helper could not')"
reply "$(call_reply tu_f3 write_file '{"path":"notes/a.md","content":"one"}')"
reply "$(text_reply 'note written')"
say "write a note"
check "a delegated write in notes is refused with the reason" 'wait_for "$OUT" "note written" && result $((mn - 2)) tu_f2 "refused by the gate: folders.ini [notes] write: agent:helper is not listed" && [ -f "$HARNESS_HOME/workspace/notes/a.md" ] && [ ! -e "$HARNESS_HOME/workspace/notes/h.md" ]'
say "/snapshots notes"
check "the run's snapshots of notes are listed" 'wait_for "$OUT" "Snapshots of notes:" && grep -F "Snapshots of notes:" "$OUT" | tail -n 1 | grep -qF "before  chat (main, owner)" && grep -F "Snapshots of notes:" "$OUT" | tail -n 1 | grep -qF "after  chat (main, owner)"'
say "/changes notes 2"
check "changes says what the run added" 'wait_for "$OUT" "Since 1: added a.md."'
say "/restore notes 1"
check "restore puts notes back as before the run and says how to undo it" 'wait_for "$OUT" "Restored notes to 1: deleted a.md. /restore notes 3 undoes it." && [ ! -e "$HARNESS_HOME/workspace/notes/a.md" ]'

# a secret the owner types reaches the log masked (and below: not at all in clear)
reply "$(text_reply 'noted, not repeated')"
say "my omnigate key is og-smoke-key-123"
check "a secret the owner types is masked in the log" 'wait_for "$OUT" "noted, not repeated" && grep -qF "my omnigate key is [secret:omnigate]" "$HARNESS_HOME/log/actions.jsonl"'

# a task added from the chat runs at the scheduler's next tick; nobody can
# answer there, so its shell call is refused, and it says so though its
# answer is NOTHING
reply "$(tool_reply tu_t1 'df -h')"
reply "$(text_reply 'NOTHING')"
before=$(asked)
say "/task add disk | every 5m | Check the disk."
check "a scheduled run skips what needs asking and says so, even answering NOTHING" 'wait_for "$OUT" "[disk] Skipped (needs approval): shell: df -h" 30 && result $mn tu_t1 "refused by the gate: no one to ask in a scheduled run" && [ "$(asked)" = "$before" ] && ! grep -qF "[disk] NOTHING" "$OUT"'

# a topic of the owner's chat with the bot is a conversation of its own
reply "$(call_reply tu_h1 recall '{"query":"flats"}')"
reply "$(text_reply 'Three flats near the station.')"
in_topic 5012 "find flats"
check "a message in a topic is answered there" 'wait_for "$OUT" "\"message_thread_id\":5012,\"text\":\"Three flats near the station.\"" && grep -qF "\"name\":\"house-search\",\"channel\":\"telegram\",\"chat\":42,\"thread\":5012" "$HARNESS_HOME/state/conversations"'
in_topic 5012 "/session"
check "/session in the topic lists its tool call" 'wait_for "$OUT" "recall flats: allow (default for this tool), ok" && grep -F "recall flats: allow" "$OUT" | grep -qF "\"message_thread_id\":5012"'
# a task whose to = names the topic posts there, with its name in front
printf '[watch]\nevery = 5m\nto = house-search\ndo = Look for new flats.\n' >>"$HARNESS_HOME/tasks.ini"
reply "$(text_reply 'Two new flats.')"
say "/reload"
check "a task with to = posts to its topic" 'wait_for "$OUT" "\"message_thread_id\":5012,\"text\":\"[watch] Two new flats.\"" 30'

kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
RPID=""
check "the log chain verifies" '"$H" log verify | grep -qF "chain intact"'
check "no secret value in the log, typed by the owner or not" '! grep -qE "og-smoke-key-123|telegram-smoke-token|brave-smoke-key|smoke-login-pass" "$HARNESS_HOME/log/actions.jsonl"'
check "a login is removed with its secrets" '"$H" login rm bot >/dev/null && "$H" login list | grep -qF "No logins." && [ ! -e "$HARNESS_STORE/login-bot-password" ] && ! grep -qF "[bot]" "$HARNESS_HOME/logins.ini"'
# left out on Windows until it has been seen to pass there: the 90 s lock
# it was skipped for is gone (HANDOFF-windows-audit.md, section 3)
if [ $windows = 0 ]; then
	check "memory list works offline" '"$H" memory list 2>/dev/null | grep -qF "I prefer short briefs"'
	check "snapshot list works offline" '"$H" snapshot list notes 2>/dev/null | grep -qF "Snapshots of notes:"'
fi

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- run output"; cat "$T/run.out"
	echo "--- outbox"; cat "$OUT" 2>/dev/null
	exit 1
fi
