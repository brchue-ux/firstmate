#!/usr/bin/env bash
# Behavior tests for firstmate's desktop still-capture tool: the MCP surface
# (bin/fm-deskcap-mcp.py) and the capture engine's CLI (bin/fm-deskcap-lib.py).
#
# Everything here is hermetic: no compositor, no session bus, no display. The
# engine's own contract unit tests live in tests/fm-deskcap.test.py and are run
# from here so a single script covers the feature. Live capture against the real
# desktop is NOT asserted here - that evidence is docs/verification/desktop-capture.md,
# reproducible with `bin/fm-deskcap-mcp.py --selftest`.
#
# The cases that matter most:
#   (a) the MCP handshake, tool listing and error mapping stay well-formed
#   (b) window scope is refused, because this slice does not implement it
#   (c) a malformed region is refused by argument shape alone, before any D-Bus
#       work, so the caller gets a useful message rather than a compositor error
#   (d) a notification produces no response and bad JSON produces a parse error,
#       so one confused client cannot wedge the server
#   (e) a non-empty batch comes back as one JSON-RPC array, since that framing is
#       what an older batching client parses
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the capture tool)"; exit 0; }

MCP="$ROOT/bin/fm-deskcap-mcp.py"
LIB="$ROOT/bin/fm-deskcap-lib.py"
TMP_ROOT=$(fm_test_tmproot fm-deskcap)
mkdir -p "$TMP_ROOT"

# A tiny reader over the server's replies, so each assertion below can name one
# field of one reply instead of re-parsing JSON in bash. A batch is answered as
# one array frame, so it looks inside those too.
cat >"$TMP_ROOT/field.py" <<'PY'
import json, sys
wanted, expr = sys.argv[1], sys.argv[2]


def find():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        frame = json.loads(line)
        for message in (frame if isinstance(frame, list) else [frame]):
            if isinstance(message, dict) and str(message.get("id")) == wanted:
                return message.get("result", message.get("error"))
    return None


r = find()
print("<no reply>" if r is None else eval(expr))  # noqa: S307 - a test-local expression over a parsed reply
PY

# The framing itself: one line per top-level reply the server wrote, as either
# `object:<id>` or `array:<id>,<id>`. This is what tells a batch answered as a
# single JSON-RPC array apart from one answered as loose newline-delimited
# objects, which no batching client would accept.
cat >"$TMP_ROOT/frames.py" <<'PY'
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    frame = json.loads(line)
    if isinstance(frame, list):
        print("array:" + ",".join(str(m.get("id")) for m in frame))
    else:
        print("object:" + str(frame.get("id")))
PY

# --- engine contract units --------------------------------------------------

if ! out=$(python3 "$ROOT/tests/fm-deskcap.test.py" 2>&1); then
  printf '%s\n' "$out" >&2
  fail "the capture engine's contract unit tests failed"
fi
assert_contains "$out" "OK" "engine unit tests did not report OK"
pass "capture engine contract units pass"

# --- MCP surface ------------------------------------------------------------

# mcp <request-json>... -> the server's responses, one JSON object per line.
mcp() {
  printf '%s\n' "$@" | python3 "$MCP" 2>"$TMP_ROOT/mcp.err"
}

# field <responses> <id> <python-expression over `r`> -> the evaluated value.
field() {
  printf '%s\n' "$1" | python3 "$TMP_ROOT/field.py" "$2" "$3"
}

# frames <responses> -> one `object:<id>` or `array:<id>,...` line per reply.
frames() {
  printf '%s\n' "$1" | python3 "$TMP_ROOT/frames.py"
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'

out=$(mcp "$INIT")
[ "$(field "$out" 1 'r["serverInfo"]["name"]')" = "firstmate-desktop-capture" ] \
  || fail "initialize did not identify the desktop-capture server"
[ "$(field "$out" 1 'r["protocolVersion"]')" = "2025-06-18" ] \
  || fail "initialize did not accept the requested protocol version"
pass "initialize negotiates a supported protocol version"

out=$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}')
[ "$(field "$out" 1 'r["protocolVersion"]')" = "2025-06-18" ] \
  || fail "an unsupported protocol version should fall back to the server default"
pass "an unsupported protocol version falls back instead of failing"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
[ "$(field "$out" 2 '[t["name"] for t in r["tools"]]')" = "['desktop_screenshot']" ] \
  || fail "the server should expose exactly the desktop_screenshot tool"
[ "$(field "$out" 2 'sorted(r["tools"][0]["inputSchema"]["properties"]["scope"]["enum"])')" = "['region', 'screen']" ] \
  || fail "this slice must offer screen and region scope and nothing else"
pass "tools/list offers screen and region scope only"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"desktop_screenshot","arguments":{"scope":"window"}}}')
[ "$(field "$out" 3 'r["isError"]')" = "True" ] || fail "window scope must be refused by this slice"
assert_contains "$(field "$out" 3 'r["content"][0]["text"]')" "window scope is not in this slice" \
  "the window-scope refusal should say why"
pass "window scope is refused with an explanation"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"desktop_screenshot","arguments":{"scope":"region"}}}')
[ "$(field "$out" 4 'r["isError"]')" = "True" ] || fail "a region without a rectangle must be refused"
assert_contains "$(field "$out" 4 'r["content"][0]["text"]')" "x, y, width, height" \
  "the refusal should name every missing rectangle field"
pass "a region scope with no rectangle names what is missing"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"desktop_screenshot","arguments":{"scope":"region","x":0,"y":0,"width":0,"height":10}}}')
[ "$(field "$out" 5 'r["isError"]')" = "True" ] || fail "a zero-width region must be refused before any capture"
pass "a malformed rectangle is refused on shape alone, with no compositor call"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}')
[ "$(field "$out" 6 'r["isError"]')" = "True" ] || fail "an unknown tool must be reported as a tool error"
pass "an unknown tool is reported as a tool error"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":7,"method":"nonsense/method"}')
[ "$(field "$out" 7 'r["code"]')" = "-32601" ] || fail "an unknown method must map to -32601"
pass "an unknown method maps to -32601"

out=$(mcp "$INIT" 'not json at all')
assert_contains "$out" '"code": -32700' "malformed JSON must map to a parse error"
assert_contains "$out" '"id": 1' "the server must keep serving after a parse error"
pass "malformed JSON is a parse error and does not wedge the server"

out=$(mcp "$INIT" '11' '{"jsonrpc":"2.0","id":10,"method":"ping"}')
assert_contains "$out" '"code": -32600' "a bare literal must be an invalid request"
[ "$(field "$out" 10 'r')" = "{}" ] || fail "the server must keep serving after a bare literal"
pass "a bare non-object is an invalid request and does not wedge the server"

# Batches left the spec in 2025-06-18 but older clients still send them. Such a
# client reads exactly one array back per batch, so the framing is asserted here
# and not just the contents; a stray literal inside one must also not take the
# process down with it.
out=$(mcp "$INIT" '[12, {"jsonrpc":"2.0","id":13,"method":"ping"}]' '{"jsonrpc":"2.0","id":14,"method":"ping"}')
[ "$(frames "$out")" = "$(printf 'object:1\narray:None,13\nobject:14')" ] \
  || fail "a batch must be answered as one array holding every response"
assert_contains "$out" '"code": -32600' "a non-object batch element must be an invalid request"
[ "$(field "$out" 13 'r')" = "{}" ] || fail "valid entries in the same batch must still be served"
[ "$(field "$out" 14 'r')" = "{}" ] || fail "a malformed batch element must not wedge the server"
pass "a batch is answered as a single array and a stray element does not wedge it"

# A notification carries no id, so it contributes no entry to the array, and a
# batch of nothing but notifications is answered with silence rather than [].
out=$(mcp "$INIT" '[{"jsonrpc":"2.0","method":"ping"},{"jsonrpc":"2.0","id":16,"method":"ping"}]')
[ "$(frames "$out")" = "$(printf 'object:1\narray:16')" ] \
  || fail "a notification inside a batch must not contribute a response entry"
out=$(mcp "$INIT" '[{"jsonrpc":"2.0","method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]' '{"jsonrpc":"2.0","id":17,"method":"ping"}')
[ "$(frames "$out")" = "$(printf 'object:1\nobject:17')" ] \
  || fail "a batch of only notifications must produce no reply at all"
pass "notifications add no batch entry and an all-notification batch is silent"

out=$(mcp "$INIT" '[]' '{"jsonrpc":"2.0","id":15,"method":"ping"}')
assert_contains "$out" '"code": -32600' "an empty batch must be an invalid request"
[ "$(field "$out" 15 'r')" = "{}" ] || fail "the server must keep serving after an empty batch"
pass "an empty batch is an invalid request rather than silence"

out=$(mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$INIT")
[ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] || fail "a notification must not produce a response"
pass "a notification produces no response"

# Wrongly shaped params are the client's mistake, so they come back as the
# protocol's invalid-params code rather than as an internal error naming a
# Python exception type that leaked out of the handler.
out=$(mcp "$INIT" \
  '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":["desktop_screenshot"]}}' \
  '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":[]}' \
  '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"desktop_screenshot","arguments":[]}}')
for id in 18 19 20; do
  [ "$(field "$out" "$id" 'r["code"]')" = "-32602" ] \
    || fail "malformed tools/call params must map to -32602, not to an internal error"
done
pass "malformed tools/call params are an invalid-params error"

out=$(mcp "$INIT" '{"jsonrpc":"2.0","id":8,"method":"resources/list"}' '{"jsonrpc":"2.0","id":9,"method":"prompts/list"}')
[ "$(field "$out" 8 'r["resources"]')" = "[]" ] || fail "resources/list should answer with an empty list"
[ "$(field "$out" 9 'r["prompts"]')" = "[]" ] || fail "prompts/list should answer with an empty list"
pass "undeclared list probes answer empty instead of erroring"

# --- CLI surface ------------------------------------------------------------

python3 "$MCP" --help >/dev/null 2>&1 || fail "the MCP server's --help should succeed"
python3 "$LIB" --help >/dev/null 2>&1 || fail "the capture engine's --help should succeed"
pass "both entry points document themselves"

set +e
python3 "$LIB" region 0 0 -5 10 "$TMP_ROOT/never.png" >/dev/null 2>"$TMP_ROOT/cli.err"
code=$?
set -e
[ "$code" -ne 0 ] || fail "the engine CLI should refuse a negative region size"
assert_absent "$TMP_ROOT/never.png" "a refused capture must not write an output file"
pass "the engine CLI refuses a negative region and writes nothing"

set +e
python3 "$LIB" screen --route magic "$TMP_ROOT/never2.png" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "an unknown route should be an argument error"
pass "the engine CLI refuses an unknown route"
