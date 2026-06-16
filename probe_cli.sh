#!/usr/bin/env bash
# =============================================================
# ER605 CLI Probe — captures raw output of real CLI commands
# Usage:
#   export ROUTER_IP=...    # or set it in .env
#   export RPASS='your-router-password'
#   ./probe_cli.sh
# Optionally override which commands to run:
#   ./probe_cli.sh "show arp" "show ip route"
# =============================================================

# Pull ROUTER_IP/ROUTER_USER/ROUTER_PORT from the shared env file if present.
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
ROUTER_IP="${ROUTER_IP:-}"
ROUTER_USER="${ROUTER_USER:-admin}"
ROUTER_PORT="${ROUTER_PORT:-22}"

# Password: RPASS or ROUTER_PASS (the env file may set the latter).
RPASS="${RPASS:-${ROUTER_PASS:-}}"

if [[ -z "$ROUTER_IP" ]]; then
    echo "ERROR: no router IP. Set ROUTER_IP in $CONFIG_FILE or export ROUTER_IP." >&2
    exit 1
fi
if [[ -z "$RPASS" ]]; then
    echo "ERROR: no password. Export RPASS or set ROUTER_PASS in $CONFIG_FILE." >&2
    exit 1
fi

# Per-command wait (seconds). Bump for slow commands like ping: DELAY=12 ./probe_cli.sh ...
DELAY="${DELAY:-4}"

# Commands to probe (privileged mode). Override via CLI args.
if [[ $# -gt 0 ]]; then
    CMDS=("$@")
else
    CMDS=(
        "show interface switchport"
        "show interface vlan"
        "show arp"
        "show ip route"
        "show system-info"
    )
fi

SSH_OPTS=(
    -tt
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=10
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -p "$ROUTER_PORT"
)

# Build the paced input stream: enable, then each command, then exit twice.
gen_input() {
    sleep 3
    printf 'enable\r\n'
    sleep 2
    for c in "${CMDS[@]}"; do
        printf '%s\r\n' "$c"
        sleep "$DELAY"
    done
    printf 'exit\r\n'   # leave privileged mode
    sleep 2
    printf 'exit\r\n'   # close session
    sleep 1
}

echo "=== Probing ${ROUTER_USER}@${ROUTER_IP} ==="
echo "=== Commands: ${CMDS[*]} ==="
echo

gen_input | sshpass -p "$RPASS" ssh "${SSH_OPTS[@]}" "${ROUTER_USER}@${ROUTER_IP}" 2>&1
