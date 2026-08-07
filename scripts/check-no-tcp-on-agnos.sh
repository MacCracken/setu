#!/bin/sh
# Assert that NO TCP symbol is reachable in agnos-active code.
#
# ⛔ WHY A GATE AND NOT A CODE REVIEW. setu 0.8.0's changelog states "the TCP arm is DELETED on agnos".
# It was deleted from `setu_connect` only. `setu_listen` and `setu_accept` kept calling
# tcp_socket/sock_bind/sock_listen/sock_accept with no #ifdef, and survived FOUR cuts (0.8.0 → 0.8.3)
# while every changelog and planning doc asserted the transport was gone. ipc bite 8's premise —
# "nothing dials 7700/7701" — was false the whole time.
#
# ⛔ A CLAIM IN A CHANGELOG IS NOT A PROPERTY OF THE CODE. This script makes it one.
#
# Method: strip every `#ifndef CYRIUS_TARGET_AGNOS ... #endif` block (Linux-only code, legitimately
# allowed to speak TCP — a different target, not a fallback), then grep what remains.
set -eu
cd "$(dirname "$0")/.."

BANNED='tcp_socket|sock_bind|sock_listen|sock_accept|sock_connect|sock_reuse|sock_set_nonblocking|sock_close|INADDR_LOOPBACK|SETU_TCP_PORT'
fail=0

for f in src/*.cyr; do
    [ -e "$f" ] || continue
    hits=$(python3 - "$f" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, depth_skip = [], 0
for i, line in enumerate(src, 1):
    t = line.strip()
    if t.startswith("#ifndef CYRIUS_TARGET_AGNOS"):
        depth_skip += 1; continue
    if t.startswith("#endif") and depth_skip:
        depth_skip -= 1; continue
    if depth_skip:
        continue
    # comments are prose, not reachable code
    if t.startswith("#"):
        continue
    out.append((i, line))
banned = re.compile(r'\b(tcp_socket|sock_bind|sock_listen|sock_accept|sock_connect|sock_reuse|sock_set_nonblocking|sock_close|INADDR_LOOPBACK|SETU_TCP_PORT)\b')
for i, line in out:
    code = line.split("#", 1)[0]
    m = banned.search(code)
    if m:
        print(f"{i}: {m.group(1)}: {code.strip()}")
PY
)
    if [ -n "$hits" ]; then
        echo "TCP reachable on agnos in $f:"
        echo "$hits"
        fail=1
    fi
done

[ $fail -eq 0 ] || { echo "FAIL: the retired TCP transport is still reachable on the agnos target"; exit 1; }
echo "no-tcp-on-agnos: clean — no TCP symbol in agnos-active code"
