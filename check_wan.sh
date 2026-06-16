#!/usr/bin/env bash
# =============================================================
# ER605 Dual-WAN Connectivity Checker (TP-Link Omada CLI)
# Tested on: ER605 v2.0, firmware 2.3.0
#
# Config precedence (highest first): CLI flag > inline env var > env file.
#   Env file : .env next to this script (git-ignored). See .env.example.
# Usage: ./check_wan.sh [--trace]               # all from .env
#        ./check_wan.sh <password> [--trace]
#        ./check_wan.sh --host <ip> <password> [--trace]
#        ROUTER_IP=... ROUTER_PASS=... ./check_wan.sh
#   --trace / -t : also run a traceroute to the public target (slower)
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

# WAN gateways to ping for per-link health (the CLI ping can't be bound to a
# WAN, so we ping each WAN's own gateway — traffic to it can only egress that
# link). Blank by default: the script auto-discovers them from "show interface
# switchport" so no site-specific IPs are needed. Set both (here or in .env) to
# run everything in ONE SSH login instead of two (saves ~1s); the script then
# warns on live-vs-config drift.
WAN1_GW="${WAN1_GW:-}"
WAN2_GW="${WAN2_GW:-}"

# Public IP to test overall internet reachability (follows the active route)
PING_PUBLIC="${PING_PUBLIC:-8.8.8.8}"

# CLI args (override everything): [--host <ip>] [--trace] [<password>].
# Traceroute follows the active route only, so it traces whichever WAN carries it.
DO_TRACE="${DO_TRACE:-0}"
PASS_ARG=""; HOST_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace|-t) DO_TRACE=1; shift ;;
        --host|-H)  HOST_ARG="$2"; shift 2 ;;
        *)          PASS_ARG="$1"; shift ;;
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

# ─── SSH / CLI DRIVER ─────────────────────────────────────────
# The ER605 CLI is interactive (no exec mode) and gives no completion signal,
# so we drive it with `expect`: type the password, enter `enable`, then send
# each command and wait for the `#` prompt to return — no blind sleeps. ER605
# runs Dropbear (legacy ssh-rsa host key), so we re-enable that algorithm.
if ! command -v expect &>/dev/null; then
    echo "ERROR: expect not found. Install it: sudo apt-get install expect" >&2
    exit 1
fi

# run_cli "cmd" "cmd" ...
# Runs each command in privileged mode and returns the raw session output.
# Waits on the prompt (not the clock), so it's as fast as the router responds.
run_cli() {
    CLI_CMDS="$(printf '%s\n' "$@")" \
    EXP_HOST="$ROUTER_IP" EXP_USER="$ROUTER_USER" \
    EXP_PASS="$ROUTER_PASS" EXP_PORT="$ROUTER_PORT" \
    expect -f - <<'EXPECT' 2>/dev/null | tr -d '\r'
        set timeout 90        ;# ceiling only (we return on prompt); high for slow tracert
        set pass $env(EXP_PASS)
        set cmds [split $env(CLI_CMDS) "\n"]

        spawn ssh -tt \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
            -p $env(EXP_PORT) $env(EXP_USER)@$env(EXP_HOST)

        expect "assword:"      ;# password prompt
        send "$pass\r"
        expect ">"             ;# base CLI prompt
        send "enable\r"
        expect "#"             ;# privileged prompt

        foreach c $cmds {
            if {$c eq ""} continue
            send "$c\r"
            expect "#"         ;# command done when prompt returns
        }
        # We already have all command output. The router doesn't reliably send
        # EOF on logout (expect eof would block the full timeout), so request
        # logout and force-close our side immediately.
        send "exit\r"; send "exit\r"
        close; wait
EXPECT
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

# Extract just the default gateway from a switchport block.
wan_gateway() { get_field "$1" "Default Gateway"; }

# Display one WAN's parsed details (stdout). If $3 (the configured gateway) is
# set and differs from the live gateway, warn about config drift.
show_wan() {
    local block="$1" label="$2" cfg_gw="$3"
    local name type status proto ip gw dns
    name=$(get_field "$block"   "Port name")
    type=$(get_field "$block"   "Vlan type")
    status=$(get_field "$block" "Routing Interface Status")
    proto=$(get_field "$block"  "Proto")
    ip=$(get_field "$block"     "Primary IP")
    gw=$(get_field "$block"     "Default Gateway")
    dns=$(get_field "$block"    "Primary DNS")

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
    if [[ -n "$cfg_gw" && -n "$gw" && "$cfg_gw" != "$gw" ]]; then
        echo -e "  ${YELLOW}⚠ configured ${cfg_gw} ≠ live ${gw} — update WAN_GW in config${RESET}"
    fi
    echo -e "  DNS       : ${dns:-—}"
    echo ""
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

# Summarise a single per-WAN gateway ping line.
summarise_gw() {
    local praw="$1" gw="$2" label="$3"
    if [[ -n "$gw" && "$gw" != "0.0.0.0" ]]; then
        ping_result "$(extract "$praw" "ping ${gw}")" "$label" "$gw"
    else
        echo -e "  ${label} : ${RED}● no gateway (down?)${RESET}"
    fi
}

# ─── MAIN ─────────────────────────────────────────────────────
print_header

# Discover mode kicks in only if a WAN gateway is left blank in config. With
# both gateways set, everything runs in a SINGLE SSH login (shows + pings).
DISCOVER=0
[[ -z "$WAN1_GW" || -z "$WAN2_GW" ]] && DISCOVER=1

CMDS=(
    "show interface switchport ${WAN1_PORT}"
    "show interface switchport ${WAN2_PORT}"
    "show arp"
)
if [[ $DISCOVER -eq 0 ]]; then
    [[ "$WAN1_GW" != "0.0.0.0" ]] && CMDS+=("ping ${WAN1_GW}")
    [[ "$WAN2_GW" != "0.0.0.0" ]] && CMDS+=("ping ${WAN2_GW}")
    CMDS+=("ping ${PING_PUBLIC}")
    [[ $DO_TRACE -eq 1 ]] && CMDS+=("tracert ${PING_PUBLIC}")
fi

echo -e "${YELLOW}► Querying router...${RESET}\n"
RAW=$(run_cli "${CMDS[@]}")

if ! grep -q '#' <<< "$RAW"; then
    echo -e "${RED}✗ Could not get a CLI prompt. Check IP, password, and SSH access.${RESET}"
    exit 1
fi

WAN1_BLOCK=$(extract "$RAW" "show interface switchport ${WAN1_PORT}")
WAN2_BLOCK=$(extract "$RAW" "show interface switchport ${WAN2_PORT}")
ARP_BLOCK=$(extract "$RAW" "show arp")

show_wan "$WAN1_BLOCK" "WAN1" "$WAN1_GW"
show_wan "$WAN2_BLOCK" "WAN2" "$WAN2_GW"

echo -e "${BOLD}── ARP Table ─────────────────────────────────────${RESET}"
grep -vE '^[[:space:]]*$' <<< "$ARP_BLOCK" | sed 's/^/  /'
echo ""

# Effective gateways + ping output. Hardcoded → pings already in RAW. Discover
# → read live gateways and run a 2nd session to ping them.
g1="$WAN1_GW"; g2="$WAN2_GW"; PRAW="$RAW"
if [[ $DISCOVER -eq 1 ]]; then
    g1=$(wan_gateway "$WAN1_BLOCK")
    g2=$(wan_gateway "$WAN2_BLOCK")
    echo -e "${YELLOW}► Testing connectivity (discovered gateways)...${RESET}\n"
    PING_CMDS=()
    [[ -n "$g1" && "$g1" != "0.0.0.0" ]] && PING_CMDS+=("ping ${g1}")
    [[ -n "$g2" && "$g2" != "0.0.0.0" ]] && PING_CMDS+=("ping ${g2}")
    PING_CMDS+=("ping ${PING_PUBLIC}")
    [[ $DO_TRACE -eq 1 ]] && PING_CMDS+=("tracert ${PING_PUBLIC}")
    PRAW=$(run_cli "${PING_CMDS[@]}")
fi

echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${RESET}"

summarise_gw "$PRAW" "$g1" "WAN1 gw "
summarise_gw "$PRAW" "$g2" "WAN2 gw "
ping_result "$(extract "$PRAW" "ping ${PING_PUBLIC}")" "Internet" "$PING_PUBLIC"

echo ""
echo -e "  ${CYAN}Note:${RESET} per-WAN lines ping each WAN's own gateway (true per-link health)."
echo -e "        The Internet line follows the router's active route (load-balance/failover)."
echo ""

# ─── Traceroute (opt-in) ──────────────────────────────────────
if [[ $DO_TRACE -eq 1 ]]; then
    TRACE_BLOCK=$(extract "$PRAW" "tracert ${PING_PUBLIC}")
    echo -e "${BOLD}── Traceroute → ${PING_PUBLIC} ──────────────────────${RESET}"
    if [[ -n "$TRACE_BLOCK" ]]; then
        grep -vE '^[[:space:]]*$' <<< "$TRACE_BLOCK" | sed 's/^/  /'
        echo -e "  ${CYAN}(via the active route — hop 1 shows which WAN it took)${RESET}"
    else
        echo -e "  ${YELLOW}no traceroute output captured${RESET}"
    fi
    echo ""
fi
