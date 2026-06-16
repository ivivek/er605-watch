#!/usr/bin/env bash
# =============================================================
# ER605 Dual-WAN Connectivity Checker (TP-Link Omada CLI)
# Tested on: ER605 v2.0, firmware 2.3.0
#
# Config precedence (highest first): CLI flag > inline env var > env file.
#   Env file : .env next to this script (git-ignored). See .env.example.
# Usage: ./check_wan.sh                         # all from .env
#        ./check_wan.sh <password>              # password as arg
#        ./check_wan.sh --host <ip> <password>
#        ROUTER_IP=... ROUTER_PASS=... ./check_wan.sh
# =============================================================

# ─── CONFIG ───────────────────────────────────────────────────
# Remember values already set in the environment (these win over the env file).
_env_ROUTER_IP="${ROUTER_IP:-}"; _env_ROUTER_PASS="${ROUTER_PASS:-}"

# Load the env file if present (git-ignored; holds site-specific values).
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Inline env vars override the file.
[[ -n "$_env_ROUTER_IP"   ]] && ROUTER_IP="$_env_ROUTER_IP"
[[ -n "$_env_ROUTER_PASS" ]] && ROUTER_PASS="$_env_ROUTER_PASS"

ROUTER_USER="${ROUTER_USER:-admin}"
ROUTER_PORT="${ROUTER_PORT:-22}"

# Which switchports are your WANs (ER605 v2: ports 1-5)
WAN1_PORT="${WAN1_PORT:-1}"
WAN2_PORT="${WAN2_PORT:-2}"

# Public IP to test overall internet reachability
PING_PUBLIC="${PING_PUBLIC:-8.8.8.8}"

# CLI args (override everything): [--host <ip>] [<password>]
PASS_ARG=""; HOST_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host|-H) HOST_ARG="$2"; shift 2 ;;
        *)         PASS_ARG="$1"; shift ;;
    esac
done
[[ -n "$HOST_ARG" ]] && ROUTER_IP="$HOST_ARG"
[[ -n "$PASS_ARG" ]] && ROUTER_PASS="$PASS_ARG"

if [[ -z "$ROUTER_IP" ]]; then
    echo "ERROR: no router IP. Set ROUTER_IP in $CONFIG_FILE, pass --host <ip>, or export ROUTER_IP." >&2
    exit 1
fi
if [[ -z "$ROUTER_PASS" ]]; then
    echo "ERROR: no password. Set ROUTER_PASS in $CONFIG_FILE, pass it as an arg, or export ROUTER_PASS." >&2
    exit 1
fi

# ─── COLORS ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── SSH ──────────────────────────────────────────────────────
# ER605 runs Dropbear and only offers legacy ssh-rsa, which modern OpenSSH
# disables by default — re-enable it. The CLI is interactive (no exec mode),
# so we allocate a PTY (-tt) and feed paced commands over stdin.
SSH_OPTS=(
    -tt
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=10
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -p "$ROUTER_PORT"
)

if ! command -v sshpass &>/dev/null; then
    echo "ERROR: sshpass not found. Install it: sudo apt-get install sshpass" >&2
    exit 1
fi

# run_cli "cmd|||delay" "cmd|||delay" ...
# Enters privileged mode, runs each command waiting <delay>s, returns raw output.
run_cli() {
    {
        sleep 3; printf 'enable\r\n'; sleep 2
        local spec cmd d
        for spec in "$@"; do
            cmd="${spec%%|||*}"
            d="${spec##*|||}"
            printf '%s\r\n' "$cmd"
            sleep "$d"
        done
        printf 'exit\r\n'; sleep 1; printf 'exit\r\n'; sleep 1
    } | sshpass -p "$ROUTER_PASS" ssh "${SSH_OPTS[@]}" "${ROUTER_USER}@${ROUTER_IP}" 2>/dev/null \
      | tr -d '\r'
}

# Extract the output block for a given command from raw session output.
extract() {
    local raw="$1" cmd="$2"
    awk -v marker="#$cmd" '
        index($0, marker)==1 { grab=1; next }
        grab && (substr($0,1,1)=="#" || substr($0,1,1)==">") { grab=0 }
        grab { print }
    ' <<< "$raw"
}

# Pull "Field......Value" (dots or colon+dots as separator) out of a block.
get_field() {
    local block="$1" label="$2"
    printf '%s\n' "$block" | grep -i "$label" | head -1 \
        | sed -E 's/\.{2,}/\x01/' | cut -d$'\x01' -f2 \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

parse_loss() { grep -oP '\d+(?=% packet loss)' <<< "$1" | head -1; }
parse_rtt()  { grep -oP 'min/avg/max = \K[0-9.]+/[0-9.]+/[0-9.]+' <<< "$1" | head -1 | awk -F/ '{print $2}'; }

# ─── OUTPUT ───────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║       ER605 Dual-WAN Status Check        ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo -e "  Router : ${ROUTER_IP}"
    echo -e "  Time   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# Print one WAN's parsed details; echoes the gateway IP on stdout (last line)
# so the caller can ping it. Human-readable lines go to stderr.
show_wan() {
    local block="$1" label="$2"
    local name type status proto ip gw dns
    name=$(get_field "$block"   "Port name")
    type=$(get_field "$block"   "Vlan type")
    status=$(get_field "$block" "Routing Interface Status")
    proto=$(get_field "$block"  "Proto")
    ip=$(get_field "$block"     "Primary IP")
    gw=$(get_field "$block"     "Default Gateway")
    dns=$(get_field "$block"    "Primary DNS")

    {
        echo -e "${BOLD}── ${label} (switchport) ───────────────────────${RESET}"
        echo -e "  Port Name : ${name:-?}"
        echo -e "  Type      : ${type:-?}"
        if [[ "${status^^}" == "UP" ]]; then
            echo -e "  Status    : ${GREEN}UP${RESET}"
        elif [[ -n "$status" ]]; then
            echo -e "  Status    : ${RED}${status}${RESET}"
        else
            echo -e "  Status    : ${YELLOW}unknown${RESET}"
        fi
        echo -e "  Proto     : ${proto:-?}"
        echo -e "  IP        : ${ip:-—}"
        echo -e "  Gateway   : ${gw:-—}"
        echo -e "  DNS       : ${dns:-—}"
        echo ""
    } >&2

    echo "$gw"
}

ping_result() {
    local block="$1" label="$2" target="$3"
    local loss rtt
    loss=$(parse_loss "$block")
    rtt=$(parse_rtt "$block")
    if [[ "$loss" == "0" ]]; then
        echo -e "  ${label} → ${target} : ${GREEN}● ONLINE${RESET} (0% loss, avg ${rtt}ms)"
    elif [[ -n "$loss" ]]; then
        echo -e "  ${label} → ${target} : ${YELLOW}● DEGRADED${RESET} (${loss}% loss)"
    else
        echo -e "  ${label} → ${target} : ${RED}● OFFLINE${RESET} (no response)"
    fi
}

# ─── MAIN ─────────────────────────────────────────────────────
print_header

echo -e "${YELLOW}► Querying router (interfaces + ARP)...${RESET}\n"
RAW=$(run_cli \
    "show interface switchport ${WAN1_PORT}|||3" \
    "show interface switchport ${WAN2_PORT}|||3" \
    "show arp|||3")

if ! grep -q '#' <<< "$RAW"; then
    echo -e "${RED}✗ Could not get a CLI prompt. Check IP, password, and SSH access.${RESET}"
    exit 1
fi

WAN1_BLOCK=$(extract "$RAW" "show interface switchport ${WAN1_PORT}")
WAN2_BLOCK=$(extract "$RAW" "show interface switchport ${WAN2_PORT}")
ARP_BLOCK=$(extract "$RAW" "show arp")

WAN1_GW=$(show_wan "$WAN1_BLOCK" "WAN1")
WAN2_GW=$(show_wan "$WAN2_BLOCK" "WAN2")

echo -e "${BOLD}── ARP Table ─────────────────────────────────────${RESET}"
grep -vE '^[[:space:]]*$' <<< "$ARP_BLOCK" | sed 's/^/  /'
echo ""

# ─── Connectivity tests ───────────────────────────────────────
echo -e "${YELLOW}► Testing connectivity (per-WAN gateway + public)...${RESET}\n"

PING_CMDS=()
[[ -n "$WAN1_GW" && "$WAN1_GW" != "0.0.0.0" ]] && PING_CMDS+=("ping ${WAN1_GW}|||12")
[[ -n "$WAN2_GW" && "$WAN2_GW" != "0.0.0.0" ]] && PING_CMDS+=("ping ${WAN2_GW}|||12")
PING_CMDS+=("ping ${PING_PUBLIC}|||12")

PRAW=$(run_cli "${PING_CMDS[@]}")

echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"

if [[ -n "$WAN1_GW" && "$WAN1_GW" != "0.0.0.0" ]]; then
    ping_result "$(extract "$PRAW" "ping ${WAN1_GW}")" "WAN1 gw " "$WAN1_GW"
else
    echo -e "  WAN1 gw  : ${RED}● no gateway (down?)${RESET}"
fi
if [[ -n "$WAN2_GW" && "$WAN2_GW" != "0.0.0.0" ]]; then
    ping_result "$(extract "$PRAW" "ping ${WAN2_GW}")" "WAN2 gw " "$WAN2_GW"
else
    echo -e "  WAN2 gw  : ${RED}● no gateway (down?)${RESET}"
fi
ping_result "$(extract "$PRAW" "ping ${PING_PUBLIC}")" "Internet" "$PING_PUBLIC"

echo ""
echo -e "  ${CYAN}Note:${RESET} per-WAN lines ping each WAN's own gateway (true per-link health)."
echo -e "        The Internet line follows the router's active route (load-balance/failover)."
echo ""
