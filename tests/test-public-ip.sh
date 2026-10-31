#!/usr/bin/env bash
# Regression guard for the public IP lookup in remnanode.sh.
#
# 4.6.2 resolved NODE_IP with a bare `curl -s -4 ifconfig.io` at load time: no
# timeout, no --fail, no validation, and `set -e` turned any curl failure into
# an immediate exit before a single line was printed. This suite pins the
# replacement contract: lazy, bounded, validated, with provider and cache
# fallbacks. It never touches the network — curl and ip are stubbed.
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"
SUITE_NAME="public-ip"
NODE_SCRIPT="${1:-$REPO_ROOT/remnanode.sh}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP_DIR="$WORK/app"
mkdir -p "$APP_DIR" "$WORK/bin"

BLOCK="$WORK/block.sh"
awk '
    /^# Public IP lookup$/ { inside = 1 }
    /^check_running_as_root\(\) \{$/ { exit }
    inside { print }
' "$NODE_SCRIPT" > "$BLOCK"

echo "== $SUITE_NAME ($(basename "$NODE_SCRIPT")) =="

it "remnanode.sh carries the public IP block"
if [ -s "$BLOCK" ]; then pass; else fail "'# Public IP lookup' block not found"; finish_suite; fi

it "NODE_IP is no longer resolved at load time"
if grep -qE '^NODE_IP=\$\(curl' "$NODE_SCRIPT"; then
    fail "a bare NODE_IP=\$(curl ...) still runs on every invocation"
else
    pass
fi

it "the provider request is bounded and rejects HTTP error bodies"
if grep -q -- 'curl -fsS' "$BLOCK" &&
   grep -q -- '--connect-timeout' "$BLOCK" &&
   grep -q -- '--max-time' "$BLOCK"; then
    pass
else
    fail "the curl call is missing -f, --connect-timeout or --max-time"
fi

# --- sandbox -----------------------------------------------------------------
# curl stub: one behaviour per call, popped from STUB_CURL_QUEUE.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
count=$(cat "$STUB_CURL_COUNTER" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$STUB_CURL_COUNTER"
echo "$*" >> "$STUB_CURL_LOG"
behaviour=$(sed -n "${count}p" "$STUB_CURL_QUEUE" 2>/dev/null)
case "$behaviour" in
    ip)   echo "203.0.113.7"; exit 0 ;;
    html) echo "<html>not an ip</html>"; exit 0 ;;
    fail) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
    hang)
        max=5
        prev=""
        for arg in "$@"; do
            [ "$prev" = "--max-time" ] && max=$arg
            prev=$arg
        done
        sleep "$max"
        echo "curl: (28) Operation timed out" >&2
        exit 28
        ;;
    *) exit 0 ;;
esac
STUB
cat > "$WORK/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"route get 1.1.1.1"*) echo "1.1.1.1 via 10.0.0.1 dev eth0 src ${STUB_IFACE_IP:-198.51.100.23} uid 0" ;;
    *"route get 2001:4860"*) echo "2001:4860:4860::8888 via fe80::1 dev eth0 src 2001:db8::5" ;;
esac
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/ip"
export PATH="$WORK/bin:$PATH"
export STUB_CURL_QUEUE="$WORK/queue"
export STUB_CURL_COUNTER="$WORK/counter"
export STUB_CURL_LOG="$WORK/curl.log"

reset_stub() {
    : > "$STUB_CURL_QUEUE"
    : > "$STUB_CURL_LOG"
    rm -f "$STUB_CURL_COUNTER"
    for behaviour in "$@"; do printf '%s\n' "$behaviour" >> "$STUB_CURL_QUEUE"; done
    rm -f "$APP_DIR/.public-ip"
}

# Load the block plus a snippet into a fresh `set -e` shell: an abort caused by
# a failed curl shows up as a non-zero exit instead of passing silently.
run_snippet() {
    cat > "$WORK/snippet.sh"
    bash -c "set -e
APP_DIR='$APP_DIR'
export STUB_CURL_QUEUE STUB_CURL_COUNTER STUB_CURL_LOG PATH
colorized_echo() { printf '%s\n' \"\$2\"; }
. '$BLOCK'
. '$WORK/snippet.sh'"
}

run() { # run <expected stdout>; snippet on stdin, warnings filtered out
    local expected=$1 out rc cleaned
    out=$(run_snippet); rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "the snippet exited $rc (set -e tripped)"
        return
    fi
    cleaned=$(printf '%s\n' "$out" | grep -v -e '^⚠️' -e '^   Find it' -e '^$')
    assert_eq "$cleaned" "$expected"
}

# --- validators --------------------------------------------------------------
reset_stub
it "only syntactically valid IPv4 addresses are accepted"
run "validators-ok" <<'EOF'
for ip in 1.2.3.4 255.255.255.255 0.0.0.0 198.51.100.23; do
    is_ipv4_address "$ip" || { echo "rejected $ip"; exit 1; }
done
for ip in 256.1.1.1 1234.1.1.1 1.2.3 1.2.3.4.5 "" 1.2.3.-1; do
    if is_ipv4_address "$ip"; then echo "accepted $ip"; exit 1; fi
done
echo validators-ok
EOF

reset_stub
it "IPv6 answers are recognised without accepting arbitrary text"
run "v6-ok" <<'EOF'
is_ipv6_address 2001:db8::1 || exit 1
is_ipv6_address ::1 || exit 1
is_ipv6_address 2001:db8:0:0:0:0:0:1 || exit 1
if is_ipv6_address "2001:db8::1/z"; then echo "accepted a prefix"; exit 1; fi
if is_ipv6_address "<html>"; then echo "accepted html"; exit 1; fi
echo v6-ok
EOF

reset_stub
it "loopback, RFC1918, link-local and CGNAT addresses are not offered as the public IP"
run "private-ok" <<'EOF'
for ip in 10.1.2.3 192.168.1.1 172.16.0.1 172.31.255.255 100.64.0.1 169.254.1.1 127.0.0.1 0.0.0.0; do
    is_private_ipv4 "$ip" || { echo "missed $ip"; exit 1; }
done
for ip in 8.8.8.8 172.32.0.1 100.128.0.1 203.0.113.7; do
    if is_private_ipv4 "$ip"; then echo "flagged $ip"; exit 1; fi
done
echo private-ok
EOF

# --- provider walk -----------------------------------------------------------
reset_stub html fail ip
it "an HTML body and a broken provider are skipped for the next answer"
run "203.0.113.7" <<'EOF'
ipv6_available() { return 1; }
detect_public_ip
EOF

reset_stub fail fail fail fail fail
it "when every provider fails the lookup fails cleanly"
run "all-failed" <<'EOF'
ipv6_available() { return 1; }
if detect_public_ip; then echo "unexpected success"; exit 1; fi
echo all-failed
EOF

# --- deadline ----------------------------------------------------------------
reset_stub hang hang hang hang hang
it "a hanging provider is cut off by the deadline"
run "elapsed<=4:1" <<'EOF'
ipv6_available() { return 1; }
PUBLIC_IP_DEADLINE=2
PUBLIC_IP_TOTAL_TIMEOUT=1
PUBLIC_IP_CONNECT_TIMEOUT=1
started=$SECONDS
if detect_public_ip; then echo "unexpected success"; exit 1; fi
echo "elapsed<=4:$(( SECONDS - started <= 4 ))"
EOF

# --- ensure_node_ip ----------------------------------------------------------
reset_stub ip
it "a preset NODE_IP is trusted and skips the network"
run "192.0.2.10" <<'EOF'
NODE_IP=192.0.2.10
ensure_node_ip
echo "$NODE_IP"
EOF
it "no provider request is made for a preset NODE_IP"
assert_eq "$(cat "$STUB_CURL_LOG")" ""

reset_stub ip
it "a successful lookup is returned and cached"
run "203.0.113.7" <<'EOF'
ipv6_available() { return 1; }
ensure_node_ip
echo "$NODE_IP"
EOF
it "the answer is cached under APP_DIR"
assert_eq "$(head -n 1 "$APP_DIR/.public-ip" 2>/dev/null)" "203.0.113.7"

reset_stub fail fail fail fail fail
it "a dead network with no cache leaves NODE_IP empty without aborting"
run "after:empty" <<'EOF'
ipv6_available() { return 1; }
ip() { return 1; }
ensure_node_ip
echo "after:${NODE_IP:-empty}"
EOF

reset_stub fail fail fail fail fail
it "a dead network falls back to the last known address"
run "198.51.100.77" <<'EOF'
ipv6_available() { return 1; }
printf '%s\n' "198.51.100.77" > "$NODE_IP_CACHE_FILE"
ensure_node_ip
echo "$NODE_IP"
EOF

reset_stub fail fail fail fail fail
it "an unparseable cache entry is not trusted"
run "empty" <<'EOF'
ipv6_available() { return 1; }
ip() { return 1; }
printf '%s\n' "<html>junk</html>" > "$NODE_IP_CACHE_FILE"
ensure_node_ip
echo "${NODE_IP:-empty}"
EOF

reset_stub fail fail fail fail fail
STUB_IFACE_IP=198.51.100.23
export STUB_IFACE_IP
it "a public interface address is used when no provider answers"
run "198.51.100.23" <<'EOF'
ipv6_available() { return 1; }
ensure_node_ip
echo "$NODE_IP"
EOF

reset_stub fail fail fail fail fail
STUB_IFACE_IP=10.0.0.5
export STUB_IFACE_IP
it "a private interface address is never presented as the public IP"
run "empty" <<'EOF'
ipv6_available() { return 1; }
ensure_node_ip
echo "${NODE_IP:-empty}"
EOF
export STUB_IFACE_IP=""

reset_stub fail fail fail fail fail
it "the lookup is attempted once per run, not once per redraw"
run "attempted=true" <<'EOF'
ipv6_available() { return 1; }
ip() { return 1; }
ensure_node_ip
ensure_node_ip
echo "attempted=$NODE_IP_ATTEMPTED"
EOF
it "the second ensure_node_ip makes no new request"
assert_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "5"

finish_suite
