#!/bin/sh
# The CLI against the stand-in server (llmcheck-fake); no model needed.
# usage: scripts/smoke.sh [path/to/llmcheck [path/to/llmcheck-fake]]
set -u

LC=${1:-zig-out/bin/llmcheck}
FAKE=${2:-zig-out/bin/llmcheck-fake}
case $LC in /* | [A-Za-z]:*) ;; *) LC=$(pwd)/$LC ;; esac
case $FAKE in /* | [A-Za-z]:*) ;; *) FAKE=$(pwd)/$FAKE ;; esac

D=$(mktemp -d /tmp/llmcheck-smoke.XXXXXX)
PIDS=
trap 'for p in $PIDS; do kill "$p" 2> /dev/null; wait "$p" 2> /dev/null; done; rm -rf "$D"' EXIT
cd "$D" || exit 1

# keys of the person running this must not reach the tests
unset LLMCHECK_API_KEY LLMCHECK_REF_API_KEY

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# expect <exit code> <text that must appear in stdout+stderr> -- <args...>
expect() {
    want=$1
    text=$2
    shift 3
    out=$("$LC" "$@" 2>&1)
    got=$?
    [ "$got" = "$want" ] || fail "llmcheck $*: exit $got, want $want; output: $out"
    case $out in *"$text"*) ;; *) fail "llmcheck $*: output lacks '$text': $out" ;; esac
    echo "ok - llmcheck $*"
}

# serve <name> [llmcheck-fake options]: starts a stand-in server and sets
# the variable <name> to its address.
serve() {
    name=$1
    shift
    "$FAKE" "$@" > "$name.out" 2>&1 &
    PIDS="$PIDS $!"
    i=0
    while ! grep -q '^listening port=' "$name.out" 2> /dev/null; do
        i=$((i + 1))
        [ $i -lt 100 ] || fail "llmcheck-fake $* did not start: $(cat "$name.out")"
        sleep 0.1
    done
    eval "$name=http://127.0.0.1:$(sed -n 's/^listening port=//p' "$name.out" | tr -d '\r')"
}

serve GOOD
serve TWIN
serve KEYED --key sesame
serve LOOSE --fault drops_grammar --fault tool_in_content
serve CUTS --fault truncate_context
serve WEIGHTS --fault weights_differ
serve TEMPLATE --fault template_differs
serve BLIND --fault no_logprobs
serve HANGS --fault hang
serve SLOW --delay 5
# nothing listens here
DEAD=http://127.0.0.1:1
# What a closed port looks like here. Normally the connection is refused at
# once. Where nothing answers at all (WSL with mirrored networking), llmcheck
# rightly says so after its timeout; the checks below then ask for a short
# one and expect that message.
DEAD_SAYS="could not connect"
DEAD_OPTS=
case $("$LC" probe "$DEAD" --timeout 2 2>&1) in
*"no answer within"*)
    DEAD_SAYS="no answer within 2 s"
    DEAD_OPTS="--timeout 2"
    ;;
esac

# ---- help, version, wrong usage ----
expect 0 "llmcheck check URL" -- help
expect 0 "llmcheck check URL" --
expect 0 "usage_match" -- help check
expect 0 "--against FILE" -- fidelity --help
expect 0 "--concurrency N" -- help bench
expect 0 "--baseline FILE" -- help probe
expect 0 "llmcheck 0." -- version
expect 2 "frobnicate" -- frobnicate "$GOOD"
expect 2 "address" -- check
expect 2 "is not an address" -- check ftp://example.test
expect 2 "no check 'nope'" -- check "$GOOD" --only nope
expect 2 "--ref" -- fidelity "$GOOD"
expect 2 "--every" -- probe "$GOOD" --count 3

# ---- check ----
expect 0 "summary pass=13 fail=0 warn=1 skip=0 model=fake-1" -- check "$GOOD"
expect 0 "summary pass=13" -- check "$GOOD/v1/"
expect 0 "check id=auth status=warn" -- check "$GOOD"
expect 0 '"summary":{"pass":13,"fail":0,"warn":1,"skip":0}' -- check "$GOOD" --json
expect 0 "summary pass=2 fail=0 warn=0 skip=0" -- check "$GOOD" --only chat,stream
expect 1 "response_format is ignored" -- check "$LOOSE"
expect 1 "not returned as tool_calls" -- check "$LOOSE" --only tools
expect 0 "fail=0" -- check "$LOOSE" --skip json_schema,json_object,tools,tools_stream
expect 1 "without a word" -- check "$CUTS" --only context
expect 1 "id=stream status=fail" -- check "$HANGS" --timeout 1 --only stream
expect 4 "$DEAD: $DEAD_SAYS" -- check "$DEAD" $DEAD_OPTS

# the key: by option, by environment, and missing
expect 0 "a request without the key is refused (HTTP 401)" -- check "$KEYED" --key sesame
export LLMCHECK_API_KEY=sesame
expect 0 "id=auth status=pass" -- check "$KEYED"
unset LLMCHECK_API_KEY
expect 1 "HTTP 401" -- check "$KEYED"
expect 1 "HTTP 401" -- check "$KEYED" --key wrong

# with a reference: token counts of the same conversations
expect 0 "id=usage_match status=pass" -- check "$GOOD" --ref "$TWIN"
expect 1 "another chat template or tokenizer" -- check "$TEMPLATE" --ref "$GOOD"
expect 4 "$DEAD: $DEAD_SAYS" -- check "$GOOD" --ref "$DEAD" $DEAD_OPTS
# the reference has its own key; the server's is not sent to it
expect 0 "id=usage_match status=pass" -- check "$GOOD" --ref "$KEYED" --ref-key sesame
expect 4 "$KEYED: the reference answers HTTP 401" -- check "$GOOD" --key sesame --ref "$KEYED"
expect 4 "$KEYED: the reference answers HTTP 401" -- fidelity "$GOOD" --key sesame --ref "$KEYED"

# ---- fidelity ----
expect 0 "verdict result=same" -- fidelity "$GOOD" --ref "$TWIN"
expect 0 "fidelity group=raw prompts=8 positions=128 mean_kl=0.0000" -- fidelity "$GOOD" --ref "$TWIN"
expect 0 '"verdict":"same"' -- fidelity "$GOOD" --ref "$TWIN" --json
expect 1 "other weights" -- fidelity "$WEIGHTS" --ref "$GOOD"
expect 1 "the chat template" -- fidelity "$TEMPLATE" --ref "$GOOD"
expect 1 "fidelity group=raw prompts=8 positions=128 mean_kl=0.0000" -- fidelity "$TEMPLATE" --ref "$GOOD"
expect 4 "verdict result=unknown" -- fidelity "$BLIND" --ref "$GOOD"
expect 4 "$DEAD: $DEAD_SAYS" -- fidelity "$GOOD" --ref "$DEAD" $DEAD_OPTS
expect 4 "$DEAD: $DEAD_SAYS" -- fidelity "$DEAD" --ref "$GOOD" $DEAD_OPTS

expect 0 "recorded file=good.json model=fake-1 prompts=16 answered=16" -- fidelity "$GOOD" --record good.json
[ -s good.json ] || fail "--record wrote nothing"
expect 0 "verdict result=same" -- fidelity "$TWIN" --against good.json
expect 1 "verdict result=differs" -- fidelity "$WEIGHTS" --against good.json
expect 4 "gave no token probabilities" -- fidelity "$BLIND" --record blind.json
echo '{"not":"a record"}' > other.json
expect 2 "is not a file made with" -- fidelity "$GOOD" --against other.json
expect 2 "cannot read" -- fidelity "$GOOD" --against missing.json

# own prompts
printf '# two of mine\nraw: The capital of France is\nchat: Name three colours.\nWhat is 2+2?\n' > mine.txt
expect 0 "fidelity group=chat prompts=2" -- fidelity "$GOOD" --ref "$TWIN" --prompts mine.txt --tokens 8
: > empty.txt
expect 2 "holds no prompts" -- fidelity "$GOOD" --ref "$TWIN" --prompts empty.txt

# ---- bench ----
expect 0 "bench model=fake-1 requests=20 errors=0 concurrency=4" -- bench "$GOOD" --requests 20 --concurrency 4
expect 0 "ttft_ms n=20" -- bench "$GOOD" --requests 20 --concurrency 4
expect 0 '"requests":20' -- bench "$GOOD" --requests 20 --concurrency 4 --json
expect 0 "late=" -- bench "$GOOD" --requests 20 --rate 200
expect 0 "errors=0" -- bench "$SLOW" --duration 0.5 --concurrency 2 --max-tokens 8
expect 0 "requests=6 errors=0" -- bench "$KEYED" --key sesame --requests 6 --concurrency 2
expect 4 "HTTP 401" -- bench "$KEYED" --requests 6 --concurrency 2
expect 4 "$DEAD: $DEAD_SAYS" -- bench "$DEAD" --requests 4 $DEAD_OPTS

# ---- probe ----
expect 0 "probe status=ok time=20" -- probe "$GOOD"
expect 0 '"status":"ok"' -- probe "$GOOD" --json
expect 4 "probe status=down" -- probe "$DEAD" $DEAD_OPTS
expect 1 "probe status=fail" -- probe "$HANGS" --timeout 1
expect 1 "models: HTTP 401" -- probe "$KEYED"
expect 0 "drift_kl=0.0000" -- probe "$TWIN" --baseline good.json
expect 1 "probe status=drift" -- probe "$WEIGHTS" --baseline good.json
expect 2 "is not a file made with" -- probe "$GOOD" --baseline other.json
n=$("$LC" probe "$GOOD" --every 0.1 --count 3 | grep -c '^probe status=ok')
[ "$n" = 3 ] || fail "probe --every 0.1 --count 3 gave $n lines, want 3"
echo "ok - llmcheck probe --every 0.1 --count 3"

echo "all smoke tests passed"
