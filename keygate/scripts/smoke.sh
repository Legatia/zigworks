#!/bin/sh
# keygate end to end, against a stand-in service on this machine. Uses a
# throwaway directory for the values, the rules and the log; never the
# system keychain.
set -u
KG=$1
ECHO=$2
W=$(mktemp -d)
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
cleanup() {
  [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null
  [ -n "${ECHO_PORT:-}" ] && curl -s "http://127.0.0.1:$ECHO_PORT/quit" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

export KEYGATE_STORE="$W/store" KEYGATE_RULES="$W/rules" KEYGATE_LOG="$W/log.jsonl"
VALUE='sk_test_smoke_value_0123456789'

"$ECHO" > "$W/echo.port" &
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/echo.port" ] && break; sleep 0.2; done
ECHO_PORT=$(tr -d '\r\n' < "$W/echo.port")

cat > "$W/rules" <<RULES
[svc]
upstream = http://127.0.0.1:$ECHO_PORT/base
header = Authorization: Bearer {secret}
allow = GET /items/
env = SVC_TOKEN
RULES
chmod 600 "$W/rules"

printf '%s\n' "$VALUE" | "$KG" add svc --stdin 2>/dev/null && ok "add from a pipe" || bad "add from a pipe"
printf '%s\n' "$VALUE" | "$KG" add svc 2>/dev/null; [ $? -eq 2 ] && ok "add refuses a pipe without --stdin" || bad "add refuses a pipe without --stdin"
printf 'short\n' | "$KG" add tiny --stdin 2>/dev/null; [ $? -eq 1 ] && ok "add refuses a short value" || bad "add refuses a short value"
"$KG" list | grep -q '^svc .* stored$' && ok "list shows it stored" || bad "list shows it stored"
"$KG" list | grep -q "$VALUE" && bad "list never shows the value" || ok "list never shows the value"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;; # no Unix permissions to check
  *)
    chmod 666 "$W/rules"
    "$KG" list >/dev/null 2>&1 && bad "refuses a rules file others can change" || ok "refuses a rules file others can change"
    chmod 600 "$W/rules"
    ;;
esac

"$KG" serve --port 0 --env-file "$W/env" > "$W/serve.out" 2> "$W/serve.err" &
SERVE_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$W/env" ] && break; sleep 0.2; done
TOKEN=$(grep '^SVC_TOKEN=' "$W/env" | cut -d= -f2- | tr -d '\r')
URL=$(grep '^KEYGATE_SVC_URL=' "$W/env" | cut -d= -f2- | tr -d '\r')
case "$TOKEN" in kg-svc-*) ok "serve gives a placeholder" ;; *) bad "serve gives a placeholder" ;; esac
grep -q "$VALUE" "$W/env" "$W/serve.out" && bad "serve never prints the value" || ok "serve never prints the value"

R=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL/items/7?q=1")
echo "$R" | grep -q '^GET /base/items/7?q=1$' && ok "request reaches the service" || bad "request reaches the service: $R"
echo "$R" | grep -q 'Authorization: Bearer \[keygate:svc\]' && ok "echoed value comes back masked" || bad "echoed value comes back masked: $R"
echo "$R" | grep -q "$VALUE" && bad "caller never sees the value" || ok "caller never sees the value"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/items/7")" = 401 ] && ok "no placeholder: 401" || bad "no placeholder: 401"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$URL/admin")" = 403 ] && ok "path outside the rules: 403" || bad "path outside the rules: 403"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "$URL/items/7")" = 403 ] && ok "method outside the rules: 403" || bad "method outside the rules: 403"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example" -H "Authorization: Bearer $TOKEN" "$URL/items/7")" = 403 ] && ok "foreign Host: 403" || bad "foreign Host: 403"

O=$("$KG" run svc -- sh -c 'echo "v=$SVC_TOKEN"' 2>/dev/null)
[ "$O" = 'v=[keygate:svc]' ] && ok "run masks the value in output" || bad "run masks the value in output: $O"
"$KG" run svc -- sh -c 'exit 3' 2>/dev/null; [ $? -eq 3 ] && ok "run passes the exit code on" || bad "run passes the exit code on"

kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
[ "$(grep -c '"result":"allowed"' "$W/log.jsonl")" -ge 3 ] && ok "allowed uses logged" || bad "allowed uses logged"
[ "$(grep -c '"result":"denied"' "$W/log.jsonl")" -ge 4 ] && ok "refusals logged" || bad "refusals logged"
grep -q -e "$VALUE" -e "$TOKEN" "$W/log.jsonl" && bad "log holds neither value nor placeholder" || ok "log holds neither value nor placeholder"

"$KG" rm svc 2>/dev/null && ok "rm" || bad "rm"
"$KG" list | grep -q 'not stored' && ok "list after rm" || bad "list after rm"

[ $fail -eq 0 ] && echo "smoke: all ok"
exit $fail
