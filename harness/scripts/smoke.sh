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
	[ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null
	[ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
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
# press_at N KEY: the owner presses that button of the Nth last question
press_at() {
	b=$(grep -F '"inline_keyboard":[[' "$OUT" 2>/dev/null | tail -n "$1" | head -n 1 |
		sed -n 's/^{"method":"sendMessage","message_id":\([0-9]*\),.*"callback_data":"\([^"]*:'"$2"'\)".*/\1 \2/p')
	[ -n "$b" ] || return 1
	inbox "{\"callback_query\":{\"id\":\"cb$inbox_n\",\"from\":{\"id\":42},\"message\":{\"message_id\":${b%% *},\"chat\":{\"id\":42}},\"data\":\"${b#* }\"}}"
}
# open_items: how many items of state/inbox are open
open_items() {
	n=$(grep -c '"status":"open"' "$HARNESS_HOME/state/inbox" 2>/dev/null)
	echo "${n:-0}"
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
# undo_button: "MESSAGE_ID DATA" of the last message's Undo button
undo_button() {
	grep -F '"callback_data":"u' "$OUT" 2>/dev/null | tail -n 1 |
		sed -n 's/^{"method":"sendMessage","message_id":\([0-9]*\),.*"callback_data":"\(u[0-9]*-[0-9a-f]*\)".*/\1 \2/p'
}
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
[provider whisper]
api = openai
url = $URL/v1
auth = none
[voice]
provider = whisper
model = large-v3-turbo
language = pl
[voice_agent]
listen = 127.0.0.1:0
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

# triggers, run by hand before the service starts: a feed trigger's run
# gets the new item as data; a page's say needs no model call
printf '<rss><channel><item><title>First</title><link>https://n.org/1</link></item></channel></rss>\n' >"$S/pages/news.xml"
printf '{"data":{"amount":"100"}}' >"$S/pages/btc.json"
cat >"$HARNESS_HOME/triggers.ini" <<EOF
[news]
feed = $URL/page/news.xml
do = Tell me what is new.

[btc]
page = $URL/page/btc.json
json = data.amount
every = 5m
match = move > 3
say = BTC {value} ({change}%)
EOF
chmod 600 "$HARNESS_HOME/triggers.ini"
"$H" trigger run news >/dev/null 2>&1
printf '<rss><channel><item><title>First</title><link>https://n.org/1</link></item><item><title>Second</title><link>https://n.org/2</link></item></channel></rss>\n' >"$S/pages/news.xml"
reply "$(text_reply 'Second is out.')"
check "a feed trigger's run answers with the new item as data" '"$H" trigger run news 2>/dev/null | grep -qF "[news] Second is out." && grep -qF "Events from trigger news" "$(req)" && grep -qF "https://n.org/2" "$(req)" && ! grep -qF "https://n.org/1" "$(req)"'
"$H" trigger run btc >/dev/null 2>&1
printf '{"data":{"amount":"104"}}' >"$S/pages/btc.json"
check "a page say sends with no model request" 'n0=$(ls "$S/requests" | wc -l) && "$H" trigger run btc 2>/dev/null | grep -qF "[btc] BTC 104 (+4.0%)" && [ "$(ls "$S/requests" | wc -l)" = "$n0" ]'

# Home Assistant's voice agent: its token stored, on a free port of 127.0.0.1
HATOKEN=ha-agent-smoke-token-1
printf '%s\n' "$HATOKEN" | "$H" secret add ha-agent --stdin 2>/dev/null
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

# a household member: the owner's code, the person's /join, their own chat
say "/member add anna"
check "the owner gets a member's code" 'wait_for "$OUT" "Code for anna: "'
MCODE=$(grep -o 'Code for anna: [A-Z0-9]*' "$OUT" | tail -n 1 | sed 's/^Code for anna: //')
inbox "{\"message\":{\"from\":{\"id\":77},\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"/join $MCODE\"}}"
check "the member joins with it from their own chat" 'wait_for "$OUT" "Hi Anna, you" && wait_for "$OUT" "anna joined" && ! grep -qF "$MCODE" "$HARNESS_HOME/log/actions.jsonl"'
reply "$(text_reply 'The hall light is off.')"
inbox "{\"message\":{\"from\":{\"id\":77},\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"is the hall light on?\"}}"
check "a member is answered in their own chat, as member:anna" 'wait_for "$OUT" "The hall light is off." && grep -F "The hall light is off." "$OUT" | grep -qF "\"chat_id\":77" && grep -qF "\"by\":\"member:anna\"" "$HARNESS_HOME/log/actions.jsonl" && grep -qF "From: Anna (member:anna)" "$(req)"'

# someone speaks in the kitchen: Home Assistant (harness-fake --ha) asks the voice agent
wait_for "$HARNESS_HOME/log/actions.jsonl" "\"event\":\"voice agent listening\"" 10
VPORT=$(grep -o '"event":"voice agent listening","address":"127[.]0[.]0[.]1:[0-9]*"' "$HARNESS_HOME/log/actions.jsonl" | tail -n 1 | sed 's/.*://; s/"//')
HA_SAID='{"model":"harness","messages":[{"role":"system","content":"You are a voice assistant for Home Assistant.\nRoom: Kitchen\nLanguage: en"},{"role":"user","content":"is the back door closed?"}]}'
reply "$(text_reply '**Yes**, the back door is closed.')"
"$F" --ha "http://127.0.0.1:$VPORT/v1/chat/completions" "$HATOKEN" "$HA_SAID" >"$T/ha-said.out" 2>&1
check "Home Assistant's request is answered for the ear, as room:kitchen" 'head -n 1 "$T/ha-said.out" | grep -qxF 200 && grep -qF "\"content\":\"Yes, the back door is closed.\"" "$T/ha-said.out" && grep -qF "\"conversation\":\"home\",\"run\":\"speech\",\"by\":\"room:kitchen\"" "$HARNESS_HOME/log/actions.jsonl" && grep -qF "Room: Kitchen." "$(req)"'
n_req=$(ls "$S/requests" | wc -l)
"$F" --ha "http://127.0.0.1:$VPORT/v1/chat/completions" "wrong-token-for-the-smoke" "$HA_SAID" >"$T/ha-wrong.out" 2>&1
check "a request with another token is refused, unheard" 'head -n 1 "$T/ha-wrong.out" | grep -qxF 401 && [ "$(ls "$S/requests" | wc -l)" = "$n_req" ] && ! grep -qF "$HATOKEN" "$HARNESS_HOME/log/actions.jsonl"'

reply "$(tool_reply tu_1 'echo smoke-ran')"
reply "$(text_reply 'done: smoke-ran')"
say "run the echo"
# the buttons carry the item's number and its own token
check "the shell call asks for approval" 'wait_for "$OUT" "\"inline_keyboard\":[[" && button day | grep -qE "^[0-9]+ i[0-9]+-[0-9a-f]{16}:day$"'
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

# a voice note: fetched from Telegram, transcribed by a local whisper
# server (the stand-in), shown quoted, then answered as typed
printf 'OggS-smoke-audio' >"$S/telegram/files/smokevoice"
printf '{"text":"what is the weather"}' >"$S/transcribe/001.json"
reply "$(text_reply 'It is sunny.')"
inbox '{"message":{"from":{"id":42},"chat":{"id":42,"type":"private"},"voice":{"file_id":"smokevoice","duration":2,"mime_type":"audio/ogg","file_size":16}}}'
check "a voice note is shown quoted, then answered" 'wait_for "$OUT" "It is sunny." && grep -qF "\"text\":\"\\\"what is the weather\\\"\"" "$OUT" && grep -qF "what is the weather" "$(req)" && grep -qF "OggS-smoke-audio" "$S/transcribe-requests/001.json"'
check "the audio is in no log; the voice note line is" '! grep -qF "OggS-smoke-audio" "$HARNESS_HOME/log/actions.jsonl" && grep -qF "\"event\":\"voice note\"" "$HARNESS_HOME/log/actions.jsonl"'
say "/quiet"
check "quiet hours are off until set" 'wait_for "$OUT" "Quiet hours are off."'

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
# Undo: the reply of a run that changed files says so, with an Undo
# button; a press takes the run's changes back and edits that message
reply "$(call_reply tu_u1 write_file '{"path":"notes/b.md","content":"two"}')"
reply "$(text_reply 'b written')"
say "write b"
check "a run's reply says what it changed and carries an Undo button" 'wait_for "$OUT" "b written" && grep -F "b written" "$OUT" | tail -n 1 | grep -qF "Changed 1 file in notes/." && undo_button | grep -qE "^[0-9]+ u[0-9]+-[0-9a-f]{16}$" && [ -f "$HARNESS_HOME/workspace/notes/b.md" ]'
b=$(undo_button)
inbox "{\"callback_query\":{\"id\":\"cb$inbox_n\",\"from\":{\"id\":42},\"message\":{\"message_id\":${b%% *},\"chat\":{\"id\":42},\"text\":\"b written\\n\\nChanged 1 file in notes/.\"},\"data\":\"${b#* }\"}}"
check "Undo takes the run's changes back and edits its message" 'wait_for "$OUT" "Undid run" && grep -F "Undid run" "$OUT" | tail -n 1 | grep -qF "\"method\":\"editMessageText\"" && grep -F "Undid run" "$OUT" | tail -n 1 | grep -qF "\"message_id\":${b%% *},\"text\":\"b written\\n\\nChanged 1 file in notes/.\\n\\nUndid run " && grep -F "Undid run" "$OUT" | tail -n 1 | grep -qF "removed notes/b.md." && [ ! -e "$HARNESS_HOME/workspace/notes/b.md" ]'

# two helpers' questions wait at once, each its own item; the newer is
# answered first, and the older still waits
before=$(asked)
reply '{"content":[{"type":"tool_use","id":"tu_q","name":"delegate","input":{"tasks":[{"task":"first","tools":["shell"]},{"task":"second","tools":["shell"]}]}}],"stop_reason":"tool_use"}'
reply "$(tool_reply h_a 'echo helper-one')"
reply "$(tool_reply h_b 'echo helper-two')"
reply "$(text_reply 'helper finished')"
reply "$(text_reply 'helper finished')"
reply "$(text_reply 'both helpers answered')"
say "ask twice at once"
check "two helpers' questions wait at once" 'wait_asked $((before + 2)) && [ "$(open_items)" = 2 ]'
press deny
check "the newer is answered first while the older waits" 'sleep 1 && [ "$(open_items)" = 1 ] && ! grep -qF "both helpers answered" "$OUT"'
press_at 2 once
check "then the older, and the turn goes on" 'wait_for "$OUT" "both helpers answered" && [ "$(open_items)" = 0 ]'

# a secret the owner types reaches the log masked (and below: not at all in clear)
reply "$(text_reply 'noted, not repeated')"
say "my omnigate key is og-smoke-key-123"
check "a secret the owner types is masked in the log" 'wait_for "$OUT" "noted, not repeated" && grep -qF "my omnigate key is [secret:omnigate]" "$HARNESS_HOME/log/actions.jsonl"'

# a task added from the chat runs at the scheduler's next tick; nobody can
# answer there, so its shell call is refused, and it says so though its
# answer is NOTHING; the call is kept as an item, posted without a sound
reply "$(tool_reply tu_t1 'df -h')"
reply "$(text_reply 'NOTHING')"
before=$(asked)
say "/task add disk | every 5m | Check the disk."
check "a scheduled run skips what needs asking and says so, even answering NOTHING" 'wait_for "$OUT" "[disk] Skipped (needs approval): shell: df -h (item " 30 && result $mn tu_t1 "refused by the gate: no one to ask in a scheduled run" && [ "$(asked)" = $((before + 1)) ] && last_question | grep -qF "could not make this call without you:" && last_question | grep -qF "\"disable_notification\":true" && ! grep -qF "[disk] NOTHING" "$OUT"'
press allow
check "Allow for this task writes a grant for that task alone" 'wait_for "$HARNESS_HOME/state/grants" "schedule:disk" 5 && grep -F "schedule:disk" "$HARNESS_HOME/state/grants" | grep -qF "df -h"'

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

# an agent definition written by hand: picked for a conversation it answers
# there with its own instructions and model; it proposes a change to itself,
# asked every time with the whole file, and the next run uses the change
cat >"$HARNESS_HOME/agents/researcher.md" <<'EOF'
---
name: researcher
description: Research across several sources; answers with links.
model: claude-haiku
tools: search, fetch, recall, agent_save
memory: pinned
---
Research one question at a time.
EOF
chmod 600 "$HARNESS_HOME/agents/researcher.md"
reloaded() { grep -c "Settings reloaded." "$OUT"; }
tries=0
while [ $tries -lt 5 ]; do
	r0=$(reloaded)
	say "/reload"
	i=0
	while [ $i -lt 30 ] && [ "$(reloaded)" -le "$r0" ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ "$(reloaded)" -gt "$r0" ] && break
	tries=$((tries + 1))
done
say "/agent researcher"
check "/agent picks a definition for the conversation" 'wait_for "$OUT" "researcher answers here from your next message."'
reply "$(text_reply 'Found it in two sources.')"
say "what changed in zig"
check "the conversation's definition answers, with its instructions and model" 'wait_for "$OUT" "Found it in two sources." && grep -qF "Research one question at a time." "$(req)" && grep -qF "\"model\":\"claude-haiku\"" "$(req)"'
say "/agents"
check "/agents lists the definitions" 'wait_for "$OUT" "researcher: Research across several sources; answers with links."'
before=$(asked)
reply "$(call_reply tu_as agent_save '{"name":"researcher","text":"---\nname: researcher\ndescription: Research across several sources; answers with links.\nmodel: claude-haiku\ntools: search, fetch, recall, agent_save\nmemory: pinned\n---\nResearch one question at a time. Cite dates.\n"}')"
reply "$(text_reply 'Saved my definition.')"
say "always cite dates"
check "agent_save asks with the whole file and no Allow 24 h" 'wait_asked $((before + 1)) && last_question | grep -qF "agent_save: researcher" && last_question | grep -qF "Cite dates." && [ -z "$(button day)" ]'
press once
check "an allowed change is written, marked, and its old file kept" 'wait_for "$OUT" "Saved my definition." && grep -qF "saved: agent:researcher " "$HARNESS_HOME/agents/researcher.md" && [ -n "$(ls "$HARNESS_HOME/state/agents/researcher/versions/")" ]'
say "/new"
wait_for "$OUT" "New conversation."
reply "$(text_reply 'Dated answer.')"
say "and now"
check "the next run uses the change" 'wait_for "$OUT" "Dated answer." && grep -qF "Cite dates." "$(req)"'
say "/agent main"

# the agent proposes a trigger: asked every time with harness's reading;
# allowed, it is added under its mark and listed
before=$(asked)
reply "$(call_reply tu_tg trigger '{"action":"add","text":"[zig]\nsearch = zig release\nsay = {title}\n"}')"
reply "$(text_reply 'Trigger added.')"
say "watch zig releases"
check "the agent's trigger add is asked with harness's reading and no Allow 24 h" 'wait_asked $((before + 1)) && last_question | grep -qF "trigger: add zig" && last_question | grep -qF "Searches for" && [ -z "$(button day)" ]'
press once
wait_for "$OUT" "Trigger added."
say "/triggers"
check "an allowed trigger is added, marked and listed" 'wait_for "$OUT" "zig (search, triggers.ini): every 6 h, says a line" && grep -qF "; added by agent:main " "$HARNESS_HOME/triggers.ini"'

# a question still open when harness stops: after a restart its button
# answers nothing, and harness says why
reply "$(tool_reply tu_r 'echo before-restart')"
before=$(asked)
say "one more command"
wait_asked $((before + 1))
kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
"$H" run >"$T/run2.out" 2>&1 &
RPID=$!
wait_for "$T/run2.out" "running on" 5
press once
check "after a restart a question's button answers nothing" 'wait_for "$OUT" "Already closed: " 10 && [ "$(open_items)" = 0 ]'

# a workflow instance waits for an approval while harness is killed and
# started again; the press arrives and the instance ends done
cat >"$HARNESS_HOME/workflows/hello.wf" <<'EOF'
workflow hello
step ask
approve:
  Go ahead with {input}?
step tell
say went ahead with {input}
EOF
chmod 600 "$HARNESS_HOME/workflows/hello.wf"
tries=0
while [ $tries -lt 5 ]; do
	r0=$(reloaded)
	say "/reload"
	i=0
	while [ $i -lt 30 ] && [ "$(reloaded)" -le "$r0" ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ "$(reloaded)" -gt "$r0" ] && break
	tries=$((tries + 1))
done
before=$(asked)
say "/workflow start hello the plan"
check "a workflow's approve waits in the inbox, its state on disk" 'wait_asked $((before + 1)) && last_question | grep -qF "[hello#1] Go ahead with the plan?" && wait_for "$HARNESS_HOME/state/workflows/hello/1/state" "\"status\":\"waiting\"" 5'
kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
"$H" run >"$T/run3.out" 2>&1 &
RPID=$!
wait_for "$T/run3.out" "running on" 5
press approve
check "after a restart the press arrives and the instance ends done" 'wait_for "$OUT" "[hello#1] went ahead with the plan" 15 && wait_for "$HARNESS_HOME/state/workflows/hello/1/state" "\"status\":\"done\"" 5'

kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
RPID=""
# the call allowed from the disk task's item runs on its next run
reply "$(tool_reply tu_t2 'df -h')"
reply "$(text_reply 'Disk is fine.')"
check "the call allowed for a task runs on its next run" '"$H" task run disk 2>/dev/null | grep -qF "[disk] Disk is fine." && grep -qF "\"tool_use_id\":\"tu_t2\"" "$(req)" && ! result $mn tu_t2 "refused"'
# the terminal prints /undo RUN under a run's answer that changed files,
# and harness undo RUN takes those changes back
reply "$(call_reply tu_u2 write_file '{"path":"notes/t.md","content":"from the terminal"}')"
reply "$(text_reply 't written')"
printf 'write t\n' | "$H" chat >"$T/chat-undo.out" 2>&1
run_t=$(sed -n 's|^/undo \([0-9][0-9]*\)$|\1|p' "$T/chat-undo.out" | tail -n 1)
check "the terminal prints /undo RUN under a run's answer that changed files" 'grep -qF "t written" "$T/chat-undo.out" && grep -qF "Changed 1 file in notes/." "$T/chat-undo.out" && [ -n "$run_t" ] && [ -f "$HARNESS_HOME/workspace/notes/t.md" ]'
check "harness undo RUN takes them back" '"$H" undo "$run_t" 2>/dev/null | grep -qF "Undid run $run_t: removed notes/t.md." && [ ! -e "$HARNESS_HOME/workspace/notes/t.md" ]'
check "the log chain verifies" '"$H" log verify | grep -qF "chain intact"'
check "no secret value in the log, typed by the owner or not" '! grep -qE "og-smoke-key-123|telegram-smoke-token|brave-smoke-key|smoke-login-pass" "$HARNESS_HOME/log/actions.jsonl"'
check "a login is removed with its secrets" '"$H" login rm bot >/dev/null && "$H" login list | grep -qF "No logins." && [ ! -e "$HARNESS_STORE/login-bot-password" ] && ! grep -qF "[bot]" "$HARNESS_HOME/logins.ini"'
check "memory list works offline" '"$H" memory list 2>/dev/null | grep -qF "I prefer short briefs"'
# people: a contacts file with Windows line ends and a folded line
printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ola Kowalska\r\nNICKNAME:Ola\r\nBDAY:1989-11-28\r\nTEL;TYPE=CELL:+48 600 100 200\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:4.0\r\nN:Nowak;Marek;;;\r\nEMAIL:marek@exam\r\n ple.com\r\nEND:VCARD\r\n' >"$T/contacts.vcf"
check "people import reads a vCard file with Windows line ends" '"$H" people import "$T/contacts.vcf" 2>/dev/null | grep -qF "From contacts.vcf: 2 new, 0 updated, 0 already known." && [ -f "$HARNESS_HOME/state/people/ola-kowalska.txt" ]'
check "people list and show work offline" '"$H" people list 2>/dev/null | grep -qF "Ola Kowalska: birthday 28 November" && "$H" people show Marek Nowak 2>/dev/null | grep -qF "Email: marek@example.com"'
check "snapshot list works offline" '"$H" snapshot list notes 2>/dev/null | grep -qF "Snapshots of notes:"'
check "agent list works offline" '"$H" agent list 2>/dev/null | grep -qF "researcher: Research across several sources"'
check "log search finds an earlier turn, offline" '"$H" log search "disk is FINE" 2>/dev/null | grep -qF "(task disk)" && "$H" log search "disk is FINE" 2>/dev/null | grep -qF "Agent: Disk is fine."'
# the tester kit: doctor's lines and the report (each makes one short model request)
reply "$(text_reply 'ok')"
check "doctor says each piece in a line, and what to do where one doesn't work" '"$H" doctor >"$T/doctor.out" 2>&1; grep -qF "Bot: @harness_test_bot answers; you are paired" "$T/doctor.out" && grep -qF "Model: claude-sonnet at omnigate answers" "$T/doctor.out" && grep -qF "harness run: not running. Start it: harness run" "$T/doctor.out" && grep -qF "Home: not connected. In the chat: /setup home" "$T/doctor.out"'
reply "$(text_reply 'ok')"
check "report writes one file, every stored secret masked" '(cd "$T" && "$H" report >"$T/report.out" 2>&1) && R=$(sed -n "s/^Wrote \(.*[.]txt\) (.*/\1/p" "$T/report.out") && [ -f "$R" ] && grep -qF "== harness doctor ==" "$R" && grep -qF "== the log" "$R" && ! grep -qE "og-smoke-key-123|telegram-smoke-token|brave-smoke-key|smoke-login-pass" "$R"'

# servers at a url (the stand-in's): one with a token, one with a sign-in
printf 'mcp-smoke-token-1\n' >"$S/mcp-token"
printf 'mcp-smoke-token-1\n' | "$H" secret add webtok --stdin 2>/dev/null
cp "$HARNESS_HOME/mcp.ini" "$T/mcp.ini.saved"
printf '[fake]\ncommand = "%s" --mcp\n[web]\nurl = %s/mcp/token\ntoken = webtok\n[cloud]\nurl = %s/mcp/signin\nlogin = oauth\n' "$F" "$URL" "$URL" >"$HARNESS_HOME/mcp.ini"
check "mcp list names each server's kind and its tools" '"$H" mcp list >"$T/mcp-list.out" 2>&1 && grep -qxF "fake (program): 3 tools" "$T/mcp-list.out" && grep -qxF "web (token webtok, stored): 3 tools" "$T/mcp-list.out" && grep -qxF "  web/echo  Echo text back." "$T/mcp-list.out" && grep -qxF "cloud (sign-in, not signed in): harness mcp login cloud" "$T/mcp-list.out"'
# the owner opens the printed link (harness-fake plays the browser)
"$H" mcp login cloud >"$T/login.out" 2>&1 &
LPID=$!
wait_for "$T/login.out" "/auth/authorize?" 10
LINK=$(grep -o 'http://127\.0\.0\.1:[0-9]*/auth/authorize?[^ ]*' "$T/login.out" | head -n 1)
"$F" --browse "$LINK" >"$T/browse.out" 2>&1
wait_for "$T/login.out" "Signed in to cloud." 10
kill "$LPID" 2>/dev/null
wait "$LPID" 2>/dev/null
check "mcp login prints a link and keeps the tokens in the store" 'grep -qF "No browser here? Forward the port first" "$T/login.out" && grep -qF "Signed in to cloud." "$T/login.out" && grep -qF "Signed in to cloud." "$T/browse.out" && grep -qF "fake-access-" "$HARNESS_STORE/mcp-cloud"'
check "the tokens are in no file of the data folder and never said" '! grep -rqF "fake-access-" "$HARNESS_HOME" && ! grep -qE "fake-(access|refresh)-" "$T/login.out"'
check "mcp list says the server is signed in, with its tools" '"$H" mcp list 2>&1 | grep -qxF "cloud (sign-in, signed in): 3 tools"'
check "mcp logout forgets the tokens" '"$H" mcp logout cloud | grep -qxF "Signed out of cloud." && [ ! -e "$HARNESS_STORE/mcp-cloud" ] && "$H" mcp logout cloud | grep -qxF "cloud was not signed in."'
# the work morning (examples/morning) against the stand-in MCP server
# playing Slack, Jira and GitHub: the reads, a digest to review, the
# replies posted once approved
EX=$(cd "$(dirname "$0")/../examples/morning" && pwd)
printf '[fake]\ncommand = "%s" --mcp\n[slack]\ncommand = "%s" --mcp --slack\n[jira]\ncommand = "%s" --mcp --jira\n[github]\ncommand = "%s" --mcp --github\n' "$F" "$F" "$F" "$F" >"$HARNESS_HOME/mcp.ini"
cp "$EX/workflows/morning.wf" "$HARNESS_HOME/workflows/morning.wf"
chmod 600 "$HARNESS_HOME/workflows/morning.wf"
cat "$EX/rules" >>"$HARNESS_HOME/rules"
# its schedule on another weekday than today: this check starts it by hand
tomorrow=$(echo "mon tue wed thu fri sat sun" | cut -d' ' -f$(($(date +%u) % 7 + 1)))
sed "s/^days = .*/days = $tomorrow/" "$EX/triggers.ini" >>"$HARNESS_HOME/triggers.ini"
check "the work morning's file reads" '"$H" workflow check "$HARNESS_HOME/workflows/morning.wf" >"$T/morning-check.out" 2>&1 && grep -qF "Workflow morning: Weekday mornings" "$T/morning-check.out"'
mn=$((mn + 1))
m_triage=$mn
cat >"$S/model/$(printf %03d $mn).json" <<'EOF'
{"content":[{"type":"text","text":"{\"digest\": \"Today: Maria needs the release notes reviewed before 11 (#release). APP-142, checkout fails on Safari, is yours and High. The Windows CI pull request on zigworks (#31) waits for your review.\", \"replies\": [{\"where\": \"slack\", \"channel\": \"#release\", \"thread_ts\": \"1732350000.000100\", \"text\": \"On it, before 11.\"}, {\"where\": \"github\", \"owner\": \"legatia\", \"repo\": \"zigworks\", \"issue\": 31, \"text\": \"Looking at it this morning.\"}], \"replies_text\": \"#release (Maria): On it, before 11.\\nzigworks #31: Looking at it this morning.\"}"}],"stop_reason":"end_turn"}
EOF
reply "$(call_reply tu_p1 slack__post_message '{"channel":"#release","thread_ts":"1732350000.000100","text":"On it, before 11."}')"
reply "$(call_reply tu_p2 github__add_issue_comment '{"owner":"legatia","repo":"zigworks","issue_number":31,"body":"Looking at it this morning."}')"
reply "$(text_reply '#release: in the thread of Maria. zigworks #31: commented.')"
"$H" run >"$T/run5.out" 2>&1 &
RPID=$!
wait_for "$T/run5.out" "running on" 15
before=$(asked)
say "/workflow start morning"
check "the work morning reads Slack, Jira and GitHub, and its digest comes to review" 'wait_asked $((before + 1)) && last_question | grep -qF "Draft to review" && last_question | grep -qF "Maria needs the release notes reviewed before 11" && grep -qF "review the release notes before 11" "$(req $m_triage)" && grep -qF "APP-142" "$(req $m_triage)" && grep -qF "Add Windows CI" "$(req $m_triage)" && grep -qF "Data (from outside" "$(req $m_triage)"'
press use
check "the digest kept is posted; the replies are asked about in plain lines" 'wait_asked $((before + 2)) && last_question | grep -qF "Post these replies?" && last_question | grep -qF "#release (Maria): On it, before 11." && grep -qF "Today: Maria needs" "$OUT"'
press approve
check "approved, the replies are posted where they belong" 'wait_for "$OUT" "Replies posted:" 15 && grep -qF "On it, before 11." "$HARNESS_HOME/state/mcp/slack/posted.jsonl" && grep -qF "Looking at it this morning." "$HARNESS_HOME/state/mcp/github/posted.jsonl"'
check "its reads asked nothing; its posts came after the approval alone" '[ "$(asked)" = $((before + 2)) ] && ! grep -qF "\"tool\":\"slack__post_message\"" "$(req $m_triage)"'
kill "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
RPID=""
cp "$T/mcp.ini.saved" "$HARNESS_HOME/mcp.ini"

# a change in the home, pushed by homemcp, fires a trigger: homemcp and
# homemcp-sim from HOMEMCP_BIN, or built next to harness (zig build in
# ../homemcp); skipped without them
# (pwd -W as above: paths homemcp, a Windows program there, can open)
# (two steps: macOS's sh, bash 3.2, ends ${...:-...} at a } inside $(...))
HM=${HOMEMCP_BIN:-}
[ -n "$HM" ] || HM=$(cd "$(dirname "$0")/../../homemcp/zig-out/bin" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })
TW=$(cd "$T" && { pwd -W 2>/dev/null || pwd; })
if [ -n "$HM" ] && [ -x "$HM/homemcp" ] && [ -x "$HM/homemcp-sim" ]; then
	"$HM/homemcp-sim" ha 0 smoke-ha-token >"$T/hasim.out" 2>&1 &
	SPID=$!
	wait_for "$T/hasim.out" "127.0.0.1:" 5
	HAPORT=$(sed -n 's/.*127[.]0[.]0[.]1:\([0-9]*\).*/\1/p' "$T/hasim.out")
	printf '[home]\nhub = homeassistant\nurl = http://127.0.0.1:%s\n[device back_door]\nid = binary_sensor.back_door\nkind = sensor\nroom = Kitchen\n' "$HAPORT" >"$T/home.ini"
	printf 'smoke-ha-token\n' | "$H" secret add homeassistant --stdin 2>/dev/null
	printf '[home]\ncommand = "%s" "%s"\nsecret = HA_TOKEN:homeassistant\n' "$HM/homemcp" "$TW/home.ini" >>"$HARNESS_HOME/mcp.ini"
	printf '\n[door]\nmcp = home resource home://device/back_door\nmatch = text has "to":"open"\nsay = The back door: {text}\n' >>"$HARNESS_HOME/triggers.ini"
	"$H" run >"$T/run4.out" 2>&1 &
	RPID=$!
	wait_for "$T/run4.out" "running on" 15
	check "harness subscribes to homemcp's back door" 'wait_for "$HARNESS_HOME/log/actions.jsonl" "\"event\":\"subscribed\",\"server\":\"home\",\"uri\":\"home://device/back_door\"" 10'
	# its first poll only marks what is there
	wait_for "$HARNESS_HOME/state/triggers/door/state" "\"polled\":true" 15
	"$HM/homemcp-sim" poke ha "$HAPORT" smoke-ha-token binary_sensor.back_door '{"contact":false}'
	# an MCP resource is polled every 15 minutes: a line within seconds was pushed
	check "the back door opening, pushed by homemcp, fires the trigger" 'wait_for "$OUT" "[door] The back door: " 15 && grep -qF "\\\"from\\\":\\\"closed\\\",\\\"to\\\":\\\"open\\\"" "$OUT"'
	kill "$RPID" 2>/dev/null
	wait "$RPID" 2>/dev/null
	RPID=""
	kill "$SPID" 2>/dev/null
	SPID=""
else
	echo "# homemcp isn't built next to harness (or HOMEMCP_BIN): the home event check is skipped"
fi

# a home butler: init asks (here --butler says yes) and turns quiet hours on
BH="$T/butler"
check "init --butler turns quiet hours on and names /setup" 'HARNESS_HOME="$BH" "$H" init --butler >"$T/binit.out" 2>&1 && grep -qE "^quiet = 22:00-07:00 " "$BH/config.ini" && grep -qF "In the chat: /setup home" "$T/binit.out" && grep -qF "harness secret add ha " "$T/binit.out"'

# the butler, set up in chat against homemcp-sim and carcloud-sim: /setup
# home through homemcp discover, every routine turned on and run against
# the stand-ins' devices, /setup car and its routine. homemcp and carcloud
# from HOMEMCP_BIN and CARCLOUD_BIN, or built next to harness; skipped
# without them
CC=${CARCLOUD_BIN:-$(cd "$(dirname "$0")/../../carcloud/zig-out/bin" 2>/dev/null && pwd)}
# wait_asked_long N: as wait_asked, for up to 30 s
wait_asked_long() {
	i=0
	while [ $i -lt 300 ]; do
		[ "$(asked)" -ge "$1" ] && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}
if [ -n "$HM" ] && [ -x "$HM/homemcp" ] && [ -x "$HM/homemcp-sim" ] && [ -n "$CC" ] && [ -x "$CC/carcloud" ] && [ -x "$CC/carcloud-sim" ]; then
	"$HM/homemcp-sim" ha 0 smoke-ha-token-1 >"$T/bhsim.out" 2>&1 &
	SPID=$!
	wait_for "$T/bhsim.out" "127.0.0.1:" 5
	BPORT=$(sed -n 's/.*127[.]0[.]0[.]1:\([0-9]*\).*/\1/p' "$T/bhsim.out")
	"$CC/carcloud-sim" 0 smoke-car-secret-1 >"$T/ccsim.out" 2>&1 &
	CPID=$!
	wait_for "$T/ccsim.out" "127.0.0.1:" 5
	CPORT=$(sed -n 's/.*127[.]0[.]0[.]1:\([0-9]*\).*/\1/p' "$T/ccsim.out")
	# its clock 03:00 and quiet hours 05:00-06:00: no routine's time
	# comes while this runs (goodnight 04:45, the car 03:30, the morning
	# 06:00), and nothing a trigger starts is held
	hh=$(date -u +%H)
	mm=$(date -u +%M)
	now_min=$((${hh#0} * 60 + ${mm#0}))
	off=$(((180 - now_min + 1440) % 1440))
	[ $off -gt 840 ] && off=$((off - 1440))
	sign=+
	[ $off -lt 0 ] && sign=- && off=$((-off))
	UTC_OFF=$(printf '%s%02d:%02d' "$sign" $((off / 60)) $((off % 60)))
	cat >"$BH/config.ini" <<EOF
[model]
url = $URL
[search]
url = $URL
[chat]
api = $URL
utc_offset = $UTC_OFF
[butler]
quiet = 05:00-06:00
homemcp = $HM/homemcp
carcloud = $CC/carcloud
escalate = 10m anna
EOF
	chmod 600 "$BH/config.ini"
	printf 'smoke-ha-token-1\n' | "$H" secret add ha --stdin 2>/dev/null
	printf 'smoke-car-secret-1\n' | "$H" secret add smartcar --stdin 2>/dev/null
	HARNESS_HOME="$BH" "$H" run >"$T/brun.out" 2>&1 &
	RPID=$!
	wait_for "$T/brun.out" "running on" 15
	BCODE=$(HARNESS_HOME="$BH" "$H" pair | sed -n 's|^/pair ||p')
	say "/pair $BCODE"
	check "a butler, paired, hears what comes next" 'wait_for "$OUT" "Next: /setup home connects your home."'
	say "/setup home http://127.0.0.1:$BPORT"
	check "/setup home reads the home through homemcp discover and shows the file first" 'wait_for "$OUT" "home.ini, as Looks right writes it:" 20 && wait_for "$OUT" "I found 17 devices in 5 rooms, and 2 people." 20 && wait_for "$OUT" "I won'"'"'t touch the front door camera or the kitchen smoke alarm." 5 && [ ! -e "$BH/home.ini" ]'
	n0=$(asked)
	press yes
	check "Looks right writes the home, starts homemcp and offers the routines" 'wait_for "$OUT" "The home is connected: 17 devices." 30 && [ -f "$BH/home.ini" ] && grep -qF "secret = HA_TOKEN:ha" "$BH/mcp.ini" && wait_asked_long $((n0 + 1)) && last_question | grep -qF "Goodnight: when you say goodnight"'
	# every routine turned on, as each is offered (the leak's fallback too)
	for r in goodnight leaving arriving morning-home leak leak-fallback smoke door-open; do
		n0=$(asked)
		press on
		[ "$r" = door-open ] || wait_asked_long $((n0 + 1))
	done
	check "every routine the home has what for is on" 'wait_for "$OUT" "That'"'"'s all the routines: 7 on." 30 && [ -f "$BH/workflows/leak.wf" ] && grep -qF "fallback 5m" "$BH/workflows/leak.wf" && grep -qF "[leak-sink_leak]" "$BH/triggers.ini" && grep -qF "[smoke-kitchen_smoke_alarm]" "$BH/triggers.ini" && grep -qF "speakers = all" "$BH/triggers.ini" && grep -qF "[door-back_door]" "$BH/triggers.ini" && grep -qF "[workflow:arriving/heat]" "$BH/rules"'
	# the triggers' first polls only mark what is there
	for tr in leak-sink_leak smoke-kitchen_smoke_alarm door-back_door everyone-left first-home; do
		wait_for "$BH/state/triggers/$tr/state" "\"polled\":true" 20
	done
	# goodnight: the lights and the heating as asked, then one tap to lock
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 lock.front_door '{"locked": false}'
	reply "$(call_reply tu_g1 home__home_set '{"device":"living_room_light","action":"off"}')"
	reply "$(call_reply tu_g2 home__home_set '{"device":"hall_thermostat","action":"temperature","value":"18"}')"
	reply "$(text_reply 'Lights are off and the heating is at 18 C.')"
	n0=$(asked)
	say "goodnight"
	check "goodnight switches what it may, then asks once before the lock" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "The front door is unlocked." && grep -qF "Lights are off and the heating is at 18 C." "$OUT" && grep -qF "set to 18" "$(req)"'
	press approve
	check "one tap locks the front door, read back from the hub" 'wait_for "$OUT" "\"text\":\"Front door locked. Good night.\"" 20 && HA_TOKEN=smoke-ha-token-1 "$HM/homemcp" check "$BH/home.ini" >"$T/bcheck1.out" 2>&1; grep -F "front_door (" "$T/bcheck1.out" | grep -qF "): locked;"'
	# a leak, pushed by homemcp: one question with the valve's own button
	n0=$(asked)
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 binary_sensor.sink_leak '{"leak": true}'
	check "a leak asks with one tap to close the water main" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "Water leak: Sink leak, Kitchen." && last_question | grep -qF "\"text\":\"Close the water main\""'
	press approve
	check "one tap closes the water main, as it reports" 'wait_for "$OUT" "\"text\":\"Water main closed (it reports closed).\"" 20 && HA_TOKEN=smoke-ha-token-1 "$HM/homemcp" check "$BH/home.ini" >"$T/bcheck2.out" 2>&1; grep -F "water_main (" "$T/bcheck2.out" | grep -qF "): closed;"'
	# the smoke alarm goes off: said at once, with one tap to say you're on it
	n0=$(asked)
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 binary_sensor.kitchen_smoke '{"smoke": true}'
	check "a smoke alarm going off is said at once, with I'm on it" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "Smoke alarm: Kitchen smoke alarm, Kitchen." && last_question | grep -qF "\"text\":\"I'"'"'m on it\""'
	press onit
	check "I'm on it: nothing is due for it any more, and nothing acted on the alarm" 'wait_for "$BH/log/actions.jsonl" "\"by\":\"owner\",\"via\":\"button\"" 20 && ! grep -F "kitchen_smoke_alarm" "$BH/log/actions.jsonl" | grep -qF "\"tool\":\"home__home_"'
	# a door opened: its routine waits 10 minutes before it looks again
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 binary_sensor.back_door '{"contact": false}'
	check "a door left open starts its routine, waiting 10 minutes" 'wait_for "$BH/state/workflows/door-open/1/state" "\"kind\":\"timer\"" 20'
	# everyone out: what is open or on, and one tap to turn the heating down
	reply "$(text_reply '{\"line\": \"The back door is open and the heating is at 18 C.\", \"warm\": true}')"
	n0=$(asked)
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 person.anna '{"home": false}'
	check "the last one out: one question for the heating" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "out. The back door is open and the heating is at 18 C." && last_question | grep -qF "Heating to 17"'
	press approve
	check "one tap turns the heating down" 'wait_for "$OUT" "\"text\":\"Heating is set to 17 °C.\"" 20 && HA_TOKEN=smoke-ha-token-1 "$HM/homemcp" check "$BH/home.ini" >"$T/bcheck3.out" 2>&1; grep -F "hall_thermostat (" "$T/bcheck3.out" | grep -qF "set to 17 °C"'
	"$HM/homemcp-sim" poke ha "$BPORT" smoke-ha-token-1 person.anna '{"home": true}'
	check "the first one back: the heating back up, in a line" 'wait_for "$OUT" "anna is home. The heating is set to 21 °C." 20'
	# the morning summary reads the house
	reply "$(call_reply tu_m1 home__home_state '{}')"
	reply "$(text_reply 'The back door is open; the heating is at 21 C.')"
	say "/workflow start morning-home"
	check "the morning summary reads the house and says it in a line" 'wait_for "$OUT" "The back door is open; the heating is at 21 C." 20 && grep -qF "living_room_light" "$(req)"'
	# the car: /setup car against Smartcar's stand-in, then its routine
	n0=$(asked)
	say "/setup car sim-client 0c5f52b4-6a39-4a66-b2bd-6fdc1a5c8b11 5a2b7c1e-sim-user http://127.0.0.1:$CPORT"
	check "/setup car shows car.ini, then the car in a line" 'wait_for "$OUT" "car.ini, as Looks right writes it:" 30 && wait_asked_long $((n0 + 1)) && last_question | grep -qF "The car answers: battery 64 %, range 294 km, plugged in, not charging, charge limit 80 %" && [ ! -e "$BH/car.ini" ]'
	n0=$(asked)
	press yes
	check "Looks right connects the car and offers its routine" 'wait_for "$OUT" "The car is connected." 30 && wait_asked_long $((n0 + 1)) && last_question | grep -qF "Car for tomorrow: at 03:30" && grep -qF "allow = charge_start, charge_stop, charge_limit" "$BH/car.ini"'
	press on
	check "the car's routine is on" 'wait_for "$OUT" "Car for tomorrow is on, at 03:30." 20'
	reply "$(text_reply '{\"line\": \"Car 64 %, 294 km, plugged in.\", \"low\": true, \"plugged\": true, \"charging\": false}')"
	n0=$(asked)
	say "/workflow start car-tomorrow"
	check "the car for tomorrow reads the car and asks to start charging" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "Car 64 %, 294 km, plugged in." && last_question | grep -qF "Start charging" && grep -qF "battery: 64%" "$(req)"'
	press approve
	check "one tap starts charging, confirmed by the car" 'wait_for "$OUT" "\"text\":\"Charging started.\"" 30 && SMARTCAR_CLIENT_SECRET=smoke-car-secret-1 "$CC/carcloud" check "$BH/car.ini" >"$T/bcheck4.out" 2>&1; grep -qx "charging: yes" "$T/bcheck4.out"'
	check "no stored secret of the butler's in its log" '! grep -qE "smoke-ha-token-1|smoke-car-secret-1" "$BH/log/actions.jsonl"'
	kill "$RPID" 2>/dev/null
	wait "$RPID" 2>/dev/null
	RPID=""
	kill "$SPID" "$CPID" 2>/dev/null
	SPID=""
	CPID=""
else
	echo "# homemcp or carcloud isn't built next to harness (or HOMEMCP_BIN, CARCLOUD_BIN): the butler's setup and routines against their stand-ins are skipped"
fi

# the diary: /setup calendar against calmcp-sim through calmcp, then a
# change the owner asks for, asked once and made, read back. calmcp from
# CALMCP_BIN, or built next to harness (zig build in ../calmcp); skipped
# without it
# (two steps: macOS's sh, bash 3.2, ends ${...:-...} at a } inside $(...))
CM=${CALMCP_BIN:-}
[ -n "$CM" ] || CM=$(cd "$(dirname "$0")/../../calmcp/zig-out/bin" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })
if [ -n "$CM" ] && [ -x "$CM/calmcp" ] && [ -x "$CM/calmcp-sim" ]; then
	"$CM/calmcp-sim" 0 owner smoke-caldav-pass --day 2026-11-23 >"$T/calsim.out" 2>&1 &
	SPID=$!
	wait_for "$T/calsim.out" "127.0.0.1:" 5
	CALPORT=$(sed -n 's/.*127[.]0[.]0[.]1:\([0-9]*\).*/\1/p' "$T/calsim.out")
	CH="$T/calhome"
	HARNESS_HOME="$CH" "$H" init >/dev/null 2>&1
	cat >"$CH/config.ini" <<EOF
[model]
url = $URL
[search]
url = $URL
[chat]
api = $URL
[butler]
calmcp = $CM/calmcp
EOF
	chmod 600 "$CH/config.ini"
	printf 'smoke-caldav-pass\n' | "$H" secret add caldav --stdin 2>/dev/null
	HARNESS_HOME="$CH" "$H" run >"$T/crun.out" 2>&1 &
	RPID=$!
	wait_for "$T/crun.out" "running on" 15
	CCODE=$(HARNESS_HOME="$CH" "$H" pair | sed -n 's|^/pair ||p')
	say "/pair $CCODE"
	wait_for "$OUT" "I answer only you from now on." 10
	n0=$(asked)
	say "/setup calendar http://127.0.0.1:$CALPORT/ owner"
	check "/setup calendar finds the calendars through calmcp discover and shows the file first" 'wait_for "$OUT" "calendar.ini, as Looks right writes it:" 20 && wait_asked_long $((n0 + 1)) && last_question | grep -qF "I found 3 calendars: Personal, Work and Birthdays. Times in Europe/Warsaw." && [ ! -e "$CH/calendar.ini" ]'
	press yes
	check "Looks right connects it, its changes asked every time" 'wait_for "$OUT" "The calendar is connected." 30 && grep -qF "money = cal_create, cal_move, cal_cancel, cal_reply" "$CH/mcp.ini" && grep -qF "secret = CALDAV_PASSWORD:caldav" "$CH/mcp.ini" && grep -qxF "change = yes" "$CH/calendar.ini"'
	reply "$(call_reply tu_cal1 calendar__cal_move '{"id":"personal/dentist-1@calmcp-sim","title":"Dentist","from":"2026-11-23 10:30","to":"2026-11-27"}')"
	reply "$(text_reply 'The dentist is on Friday at 10:30.')"
	n0=$(asked)
	say "move the dentist to Friday"
	check "a change the owner asks for is asked, the exact call, before anything is written" 'wait_asked_long $((n0 + 1)) && last_question | grep -qF "calendar/cal_move" && last_question | grep -qF "Dentist" && ! python3 -c "import sys,urllib.request; sys.exit(0 if b\"20261127T103000\" in urllib.request.urlopen(sys.argv[1]).read() else 1)" "http://127.0.0.1:$CALPORT/sim/object?path=/dav/calendars/owner/personal/dentist-1.ics"'
	press once
	check "one tap moves it in its own zone, read back from the calendar" 'wait_for "$OUT" "The dentist is on Friday at 10:30." 30 && grep -qF "Moved: Dentist is now Fri 27 Nov 2026 10:30" "$(req)" && python3 -c "import sys,urllib.request; sys.exit(0 if b\"DTSTART;TZID=Europe/Warsaw:20261127T103000\" in urllib.request.urlopen(sys.argv[1]).read() else 1)" "http://127.0.0.1:$CALPORT/sim/object?path=/dav/calendars/owner/personal/dentist-1.ics"'
	check "no calendar password in the log" '! grep -qF "smoke-caldav-pass" "$CH/log/actions.jsonl"'
	kill "$RPID" 2>/dev/null
	wait "$RPID" 2>/dev/null
	RPID=""
	kill "$SPID" 2>/dev/null
	SPID=""
else
	echo "# calmcp isn't built next to harness (or CALMCP_BIN): the calendar's setup and an asked change are skipped"
fi

if [ $fail = 0 ]; then echo "smoke: all ok"; else
	echo "smoke: FAILED"
	echo "--- run output"; cat "$T/run.out"
	[ -f "$T/brun.out" ] && { echo "--- the butler's run output"; cat "$T/brun.out"; }
	[ -f "$T/crun.out" ] && { echo "--- the calendar's run output"; cat "$T/crun.out"; }
	for x in bcheck1 bcheck2 bcheck3 bcheck4; do [ -f "$T/$x.out" ] && { echo "--- $x"; cat "$T/$x.out"; }; done
	echo "--- outbox"; cat "$OUT" 2>/dev/null
	exit 1
fi
