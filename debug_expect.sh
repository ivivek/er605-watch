#!/usr/bin/env bash
# Times each step of a full CLI session to locate stalls.
# Usage: ROUTER_IP=... RPASS='pass' ./debug_expect.sh   (or set them in .env)
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
ROUTER_IP="${ROUTER_IP:-}"; ROUTER_USER="${ROUTER_USER:-admin}"; ROUTER_PORT="${ROUTER_PORT:-22}"
RPASS="${RPASS:-${ROUTER_PASS:-}}"
[[ -z "$ROUTER_IP" ]] && { echo "no ROUTER_IP (set it in $CONFIG_FILE or export it)"; exit 1; }
[[ -z "$RPASS" ]] && { echo "no password (export RPASS or set ROUTER_PASS in $CONFIG_FILE)"; exit 1; }

TMP=$(mktemp --suffix=.exp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'EXPECT'
    log_user 0
    set timeout 30
    set t0 [clock milliseconds]
    proc mark {label} {
        global t0
        set now [clock milliseconds]
        send_user [format "%7d ms  %s\n" [expr {$now - $t0}] $label]
        set t0 $now
    }
    set pass $env(EXP_PASS)
    spawn ssh -tt \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -p $env(EXP_PORT) $env(EXP_USER)@$env(EXP_HOST)
    mark "spawned"
    expect "assword:"; mark "got password prompt"
    send "$pass\r"
    expect ">";        mark "got base prompt >"
    send "enable\r"
    expect "#";        mark "got privileged prompt #"
    send "show interface switchport 1\r"; expect "#"; mark "show switchport 1"
    send "show arp\r";                    expect "#"; mark "show arp"
    send "ping 8.8.8.8\r";                expect "#"; mark "ping 8.8.8.8"
    send "exit\r"; expect ">";            mark "exit -> >"
    send "exit\r"; expect eof;            mark "exit -> eof (closed)"
EXPECT

EXP_HOST="$ROUTER_IP" EXP_USER="$ROUTER_USER" EXP_PASS="$RPASS" EXP_PORT="$ROUTER_PORT" \
    expect -f "$TMP"
