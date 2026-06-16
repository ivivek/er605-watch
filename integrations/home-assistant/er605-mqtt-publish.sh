#!/usr/bin/env bash
# =============================================================
# ER605 → MQTT publisher for Home Assistant
#
# Runs `er605-watch --json` and pushes the result to an MQTT broker (the
# Mosquitto add-on on HAOS). Also publishes MQTT Discovery configs so HA
# auto-creates the entities — no HA YAML editing. Designed to be run on a
# loop by a systemd timer (or cron) on an always-on Linux box that can reach
# both the router and the broker. Router credentials never leave this box.
#
# Config: repo-root .env (ROUTER_*) + er605-mqtt.env next to this script
#         (MQTT_*). See er605-mqtt.env.example.
#
# Flags:
#   --full            run er605-watch in full mode (pings/RTT) instead of --fast
#   --discovery-only  (re)publish only the Discovery configs, then exit
#   -h | --help       this help
#
# Exit code mirrors er605-watch: 0 all up · 1 one down · 2 both down
#   · 3 router unreachable · 4 usage/config. (5 = MQTT publish failure.)
# =============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WATCH="$REPO_ROOT/er605-watch"

# ─── ARGS ─────────────────────────────────────────────────────
MODE_FLAG="--fast"
DISCOVERY_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)           MODE_FLAG=""; shift ;;
        --fast)           MODE_FLAG="--fast"; shift ;;
        --discovery-only) DISCOVERY_ONLY=1; shift ;;
        -h|--help)        sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg '$1' (try --help)" >&2; exit 4 ;;
    esac
done

# ─── CONFIG ───────────────────────────────────────────────────
# Router creds come from the repo-root .env (shared with er605-watch); er605-watch
# reads that file itself. We source it too — only for the optional WANn_ISP labels
# used to name the HA entities. (ROUTER_* leaking into our env is harmless.)
# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/.env" ]] && source "$REPO_ROOT/.env"

# Then the MQTT settings. Inline env vars still win over the file (set before -u).
MQTT_ENV="${MQTT_ENV:-$HERE/er605-mqtt.env}"
if [[ -f "$MQTT_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$MQTT_ENV"
else
    echo "ERROR: $MQTT_ENV not found. Copy er605-mqtt.env.example and fill it in." >&2
    exit 4
fi

MQTT_HOST="${MQTT_HOST:-}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_BASE="${MQTT_BASE:-er605}"
DISCOVERY_PREFIX="${DISCOVERY_PREFIX:-homeassistant}"
EXPIRE_AFTER="${EXPIRE_AFTER:-180}"
MQTT_TLS="${MQTT_TLS:-0}"
MQTT_CAFILE="${MQTT_CAFILE:-}"

# Per-WAN entity labels: "ISP (WANn)" if WANn_ISP is set in the root .env, else
# "WANn". Only the friendly name changes — object_id/unique_id stay wan1/wan2 so
# renaming an ISP relabels the entity in place (no duplicates, history kept).
WAN1_LABEL="${WAN1_ISP:+${WAN1_ISP} (WAN1)}"; WAN1_LABEL="${WAN1_LABEL:-WAN1}"
WAN2_LABEL="${WAN2_ISP:+${WAN2_ISP} (WAN2)}"; WAN2_LABEL="${WAN2_LABEL:-WAN2}"

[[ -z "$MQTT_HOST" ]] && { echo "ERROR: MQTT_HOST not set (in $MQTT_ENV)." >&2; exit 4; }

# ─── REQUIRE TOOLS ────────────────────────────────────────────
for tool in jq mosquitto_pub; do
    if ! command -v "$tool" &>/dev/null; then
        case "$tool" in
            jq)            hint="sudo apt-get install jq" ;;
            mosquitto_pub) hint="sudo apt-get install mosquitto-clients" ;;
        esac
        echo "ERROR: '$tool' not found. Install it: $hint" >&2
        exit 4
    fi
done
[[ -x "$WATCH" ]] || { echo "ERROR: er605-watch not found/executable at $WATCH" >&2; exit 4; }

# ─── MQTT HELPERS ─────────────────────────────────────────────
STATUS_TOPIC="$MQTT_BASE/status"
AVAIL_TOPIC="$MQTT_BASE/availability"

# pub <topic> <payload> [extra mosquitto_pub args...]
pub() {
    local topic="$1" payload="$2"; shift 2
    local args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -m "$payload" "$@")
    [[ -n "$MQTT_USER" ]] && args+=(-u "$MQTT_USER")
    [[ -n "$MQTT_PASS" ]] && args+=(-P "$MQTT_PASS")
    if [[ "$MQTT_TLS" == "1" ]]; then
        if [[ -n "$MQTT_CAFILE" ]]; then args+=(--cafile "$MQTT_CAFILE")
        else args+=(--capath /etc/ssl/certs); fi
    fi
    mosquitto_pub "${args[@]}"
}

# ─── DISCOVERY ────────────────────────────────────────────────
# One shared device block groups all entities under "ER605 Router" in HA.
DEVICE='{"identifiers":["er605"],"name":"ER605 Router","manufacturer":"TP-Link","model":"ER605 v2"}'

# disc <component> <object_id> <config-json-fragment>
# Wraps a per-entity config with the shared device/availability/expiry fields
# and publishes it retained to the Discovery config topic.
disc() {
    local component="$1" object_id="$2" frag="$3"
    local topic="$DISCOVERY_PREFIX/$component/${MQTT_BASE}_${object_id}/config"
    local cfg
    cfg=$(jq -n \
        --argjson base "$frag" \
        --argjson device "$DEVICE" \
        --arg avail "$AVAIL_TOPIC" \
        --arg state "$STATUS_TOPIC" \
        --arg uid "${MQTT_BASE}_${object_id}" \
        --argjson expire "$EXPIRE_AFTER" \
        '$base + {
            state_topic: $state,
            availability_topic: $avail,
            expire_after: $expire,
            unique_id: $uid,
            device: $device
        }')
    pub "$topic" "$cfg" -r
}

publish_discovery() {
    # Remove entities that were renamed/replaced: publish an empty retained
    # payload to their old config topics so HA deletes them (no orphans).
    # Safe to repeat every run. (both_down/unreachable → internet/router.)
    for old in binary_sensor/${MQTT_BASE}_both_down binary_sensor/${MQTT_BASE}_unreachable; do
        pub "$DISCOVERY_PREFIX/$old/config" "" -r
    done

    # Overall status sensor — carries the whole status JSON as attributes.
    disc sensor overall "$(jq -n --arg s "$STATUS_TOPIC" '{
        name:"Overall status", object_id:"er605_overall", icon:"mdi:router-network",
        value_template:"{{ value_json.overall }}", json_attributes_topic:$s }')"

    # Per-WAN connectivity binary sensors. Booleans arrive as Python-rendered
    # "True"/"False" strings through the template, hence payload_on/off.
    disc binary_sensor wan1 "$(jq -n --arg name "$WAN1_LABEL" '{
        name:$name, object_id:"er605_wan1", device_class:"connectivity",
        value_template:"{{ value_json.wans[0].up }}", payload_on:"True", payload_off:"False" }')"
    disc binary_sensor wan2 "$(jq -n --arg name "$WAN2_LABEL" '{
        name:$name, object_id:"er605_wan2", device_class:"connectivity",
        value_template:"{{ value_json.wans[1].up }}", payload_on:"True", payload_off:"False" }')"

    # Internet reachability (connectivity): Connected when overall is ok/degraded,
    # Disconnected when down or unreachable. Reads naturally — no OK/Problem.
    disc binary_sensor internet "$(jq -n \
        --arg vt "{{ value_json.overall in ['ok','degraded'] }}" '{
        name:"Internet", object_id:"er605_internet", device_class:"connectivity",
        value_template:$vt, payload_on:"True", payload_off:"False" }')"

    # Router reachability (connectivity): Disconnected only when the router itself
    # is unreachable (power/box) — distinct from a WAN outage.
    disc binary_sensor router "$(jq -n \
        --arg vt "{{ value_json.overall != 'unreachable' }}" '{
        name:"Router", object_id:"er605_router", device_class:"connectivity",
        value_template:$vt, payload_on:"True", payload_off:"False" }')"

    # RTT sensors — only meaningful in full mode; guard the null ping in fast.
    disc sensor wan1_rtt "$(jq -n --arg name "$WAN1_LABEL RTT" '{
        name:$name, object_id:"er605_wan1_rtt", unit_of_measurement:"ms",
        state_class:"measurement", icon:"mdi:speedometer",
        value_template:"{{ value_json.wans[0].ping.rtt_ms if value_json.wans[0].ping else none }}" }')"
    disc sensor wan2_rtt "$(jq -n --arg name "$WAN2_LABEL RTT" '{
        name:$name, object_id:"er605_wan2_rtt", unit_of_measurement:"ms",
        state_class:"measurement", icon:"mdi:speedometer",
        value_template:"{{ value_json.wans[1].ping.rtt_ms if value_json.wans[1].ping else none }}" }')"
    disc sensor internet_rtt "$(jq -n '{
        name:"Internet RTT", object_id:"er605_internet_rtt", unit_of_measurement:"ms",
        state_class:"measurement", icon:"mdi:speedometer",
        value_template:"{{ value_json.internet.rtt_ms if value_json.internet else none }}" }')"
}

# ─── RUN ──────────────────────────────────────────────────────
echo ">> publishing MQTT Discovery configs to $DISCOVERY_PREFIX/.../$MQTT_BASE" >&2
publish_discovery

if [[ $DISCOVERY_ONLY -eq 1 ]]; then
    echo ">> --discovery-only: done." >&2
    exit 0
fi

# Run the watcher. stdout = JSON, stderr = progress (let it flow to our stderr/
# the journal). Capture the exit code — it is the health signal.
echo ">> running er605-watch $MODE_FLAG --json" >&2
JSON="$($WATCH $MODE_FLAG --json)"
WATCH_EXIT=$?

if [[ -z "$JSON" ]]; then
    echo "ERROR: er605-watch produced no JSON (exit $WATCH_EXIT)" >&2
    # Still mark the device available so the entity shows 'unreachable' rather
    # than going stale-unavailable, but we have nothing to publish to status.
    exit "${WATCH_EXIT:-3}"
fi

# Publish status (retained so HA has it immediately after a restart) then
# availability. expire_after (in the discovery configs) handles dead-publisher
# detection — no LWT needed for a periodic one-shot.
if ! pub "$STATUS_TOPIC" "$JSON" -r; then
    echo "ERROR: failed to publish status to $MQTT_HOST:$MQTT_PORT" >&2
    exit 5
fi
pub "$AVAIL_TOPIC" "online" -r || true

echo ">> published status (er605-watch exit $WATCH_EXIT)" >&2
exit "$WATCH_EXIT"
