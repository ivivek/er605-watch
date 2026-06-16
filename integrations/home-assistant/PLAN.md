# Home Assistant integration — implementation plan

Self-contained handoff doc. Goal: surface ER605 dual-WAN status in Home Assistant
(running **HAOS on a Raspberry Pi**) so you get phone alerts, dashboards, history,
and automations. Everything needed to start fresh is here.

---

## 0. Context (what already exists)

- Repo root: `er605-watch` is the main script. It already supports:
  - `--json` / `-j` → emits one JSON object on **stdout** (progress on **stderr**). Needs `jq`.
  - `--fast` / `-f` → link status only, **skips pings/traceroute** (~3s). Good for frequent polling.
  - `--trace`, `--host <ip>`, password as arg.
  - **Exit codes:** `0` all WANs up · `1` one down · `2` both down · `3` router unreachable · `4` usage/config error.
- Config comes from a git-ignored `.env` (ROUTER_IP, ROUTER_PASS, optional WAN1_GW/WAN2_GW, etc.).
- This integration must **not** put secrets in git. MQTT creds + broker host go in `.env` too.

### `er605-watch --json` output shape (the contract to publish)

```json
{
  "timestamp": "2026-06-17T02:39:53+05:30",
  "router": "192.168.0.1",
  "mode": "full",                       // or "fast"
  "overall": "ok",                      // ok | degraded | down | unreachable
  "wans": [
    { "port": 1, "name": "WAN1", "type": "wan", "status": "UP",
      "proto": "dhcp", "ip": "<wan-ip>/<mask>", "gateway": "<gw-ip>", "up": true,
      "ping": { "target":"g.w.y.z", "loss_pct":0, "rtt_ms":3.9, "state":"online", "online":true } },
    { "port": 2, "name": "WAN/LAN2", ... }
  ],
  "internet": { "target":"8.8.8.8", "loss_pct":0, "rtt_ms":4.8, "state":"online", "online":true },
  "arp": [ { "interface":"vlan4094", "ip":"...", "mac":"...", "type":"Dynamic" } ],
  "traceroute": null
}
```
In `--fast` mode: `mode:"fast"`, each `wans[].ping` is `null`, `wans[].up` comes from the
switchport link status, and `internet` is `null`. On router failure (`exit 3`) the JSON is
`{ "router":..., "overall":"unreachable", "error":"..." }`.

---

## 1. Decisions already made

- **HA on the Pi is HAOS** (appliance image) → it's an unsuitable host for this `expect`-driven
  poller. HA's `shell_command`/`command_line` integrations run inside the `homeassistant` container,
  which: (a) ships only a limited toolset (`ssh`/`curl`/`sh` are present, but **`expect` and `jq`
  are not** — and our driver fundamentally needs `expect`, see CLAUDE.md §2/§4/§6); (b) imposes a
  **60s command timeout** (`--trace` can exceed it); (c) has a **non-persistent filesystem** outside
  `/config`. The "Advanced SSH & Web Terminal" add-on *could* install these tools, but hosting a
  recurring PTY poller inside an appliance add-on is fragile. → Run the poller off-box instead.
- **Publisher runs on a separate always-on Linux box** (NAS/server/mini-PC) that can reach the
  router and the Pi on the LAN.
- **Transport = MQTT push.** Publisher → MQTT broker → HA subscribes. Router credentials stay on
  the publisher box; HA never sees them.
- **Broker = Mosquitto add-on on HAOS** (standard).
- **Entity creation = MQTT Discovery** (publisher sends `homeassistant/.../config` topics; HA
  auto-creates entities). No editing HA YAML files.

### Architecture

```
[always-on box]  --SSH/expect-->  [ER605 router]
   er605-watch --fast --json
        | (systemd timer, ~60s)
        v  mosquitto_pub  (MQTT 1883)
[Raspberry Pi / HAOS]
   Mosquitto add-on (broker)  <-- publisher connects here
   Home Assistant (MQTT integration)  --> auto-created entities --> automations/dashboard
```

---

## 2. Prerequisites to gather before coding

Fill these into the publisher box's `.env` (or a dedicated section):

- `MQTT_HOST` = the Raspberry Pi's LAN IP (the broker). `MQTT_PORT` = 1883 (or 8883 for TLS).
- `MQTT_USER` / `MQTT_PASS` = an MQTT login created in the Mosquitto add-on.
- `MQTT_BASE` = base topic, default `er605`.
- Publisher box **OS/init**: assume **systemd** Linux (timer + service). If it's a NAS
  (Synology/QNAP) or Docker host, swap the scheduler (cron, NAS task scheduler, or a looping
  container) — see §6.
- Poll interval: default **60s** for `--fast`; optional slower **full** publish (e.g. 300s).

---

## 3. Files to create (all under `integrations/home-assistant/`)

```
integrations/home-assistant/
  PLAN.md                     # this file
  er605-mqtt-publish.sh       # runs er605-watch --json, publishes to MQTT (+ discovery)
  er605-mqtt.env.example      # MQTT_HOST/USER/PASS/BASE template (real one git-ignored)
  systemd/
    er605-mqtt.service        # oneshot: runs the publisher
    er605-mqtt.timer          # schedule (e.g. OnUnitActiveSec=60s)
  README.md                   # setup steps + example automations
```
Add `integrations/home-assistant/er605-mqtt.env` to the repo `.gitignore` (or reuse root `.env`).

---

## 4. Publisher script spec (`er605-mqtt-publish.sh`)

Responsibilities, in order:

1. **Load config**: source root `.env` (for ROUTER_*) and the MQTT env (MQTT_HOST/USER/PASS/BASE).
   Resolve the path to `er605-watch` relative to this script (`../../er605-watch`).
2. **Require**: `jq`, `mosquitto_pub` (from `mosquitto-clients`). Error out with install hints.
3. **(once per boot / or every run) Publish MQTT Discovery configs** (retained) so HA creates
   entities. One config message per entity (see §5). Idempotent — safe to resend each run.
4. **Run** `er605-watch --fast --json` (capture stdout = JSON; stderr = progress, discard or log).
   Capture the **exit code** too.
5. **Publish the JSON** to `${MQTT_BASE}/status` with **retain** (`-r`).
6. **Publish availability** `online` to `${MQTT_BASE}/availability` (retain). (See robustness §7 —
   prefer `expire_after` over LWT for a periodic one-shot publisher.)
7. Exit with the er605-watch exit code (so the timer/journal reflects health).

CLI: support `--full` to run full mode (with pings) instead of `--fast`, and `--discovery-only`
to (re)publish just the discovery configs.

Publish commands look like:
```
mosquitto_pub -h "$MQTT_HOST" -p "${MQTT_PORT:-1883}" -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t "${MQTT_BASE}/status" -r -m "$json"
```

### Topic design
- `er605/status`        — retained JSON (the §0 payload)
- `er605/availability`  — `online` / `offline`
- `homeassistant/sensor/er605/overall/config`            — discovery (retained)
- `homeassistant/binary_sensor/er605/wan1/config`        — discovery
- `homeassistant/binary_sensor/er605/wan2/config`        — discovery
- `homeassistant/binary_sensor/er605/both_down/config`   — discovery
- (optional) `homeassistant/sensor/er605/wan1_rtt/config`, `wan2_rtt`, `internet_rtt`

---

## 5. Entities (via MQTT Discovery)

All share one `device` block so they group under a single "ER605 Router" device:
```json
"device": { "identifiers": ["er605"], "name": "ER605 Router", "manufacturer": "TP-Link", "model": "ER605 v2" }
```
Each config also sets `availability_topic: er605/availability` and `expire_after: 180`.

| Entity | Component | object_id | value_template (from `er605/status`) | notes |
|---|---|---|---|---|
| Overall status | `sensor` | overall | `{{ value_json.overall }}` | `ok/degraded/down`; `json_attributes_topic` = status for IPs/RTT |
| WAN1 up | `binary_sensor` | wan1 | `{{ value_json.wans[0].up }}` | `device_class: connectivity`, `payload_on:"True"`, `payload_off:"False"` |
| WAN2 up | `binary_sensor` | wan2 | `{{ value_json.wans[1].up }}` | same |
| Both WANs down | `binary_sensor` | both_down | `{{ value_json.overall == 'down' }}` | `device_class: problem`, on=`True` |
| WAN1 RTT (opt) | `sensor` | wan1_rtt | `{{ value_json.wans[0].ping.rtt_ms }}` | `unit_of_measurement:"ms"`; only meaningful in full mode |

> Note: through MQTT, booleans arrive as the strings `True`/`False` (Python bools rendered by the
> template), hence `payload_on:"True"`. Verify and adjust if you template to `'on'/'off'` instead.

---

## 6. Scheduler (systemd assumed)

`er605-mqtt.service` (oneshot):
```
[Unit]
Description=Publish ER605 WAN status to MQTT
After=network-online.target
[Service]
Type=oneshot
ExecStart=/path/to/integrations/home-assistant/er605-mqtt-publish.sh
```
`er605-mqtt.timer`:
```
[Unit]
Description=Run ER605 MQTT publisher periodically
[Timer]
OnBootSec=30
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
```
Enable: `systemctl enable --now er605-mqtt.timer`. Logs: `journalctl -u er605-mqtt.service`.

Non-systemd alternatives: cron (`* * * * * /path/.../er605-mqtt-publish.sh`), a NAS task scheduler,
or a small looping Docker container (`while true; do publish; sleep 60; done`).

---

## 7. Robustness details (don't skip)

1. **Dead-publisher detection — use `expire_after`, NOT LWT.** The publisher is a *periodic
   one-shot* (`mosquitto_pub` connects, publishes, disconnects), so an MQTT Last-Will would fire on
   every normal disconnect. Instead set `expire_after: 180` (≈3× the interval) in each discovery
   config: if HA gets no update for that long, the entity goes **unavailable** instead of showing a
   stale `ok`. (If you later make the publisher a long-running daemon with a persistent connection,
   LWT to `er605/availability` becomes the better option.)
2. **Retain** (`-r`) the status + discovery messages so HA has values immediately after a restart.
3. **Cadence:** `--fast` every 60s by default. Optionally a second timer publishing **full** mode
   (RTT/loss) every ~300s to a different topic / extra sensors. Don't full-poll every minute (router
   load + ~13s runtime).
4. **Unreachable handling:** when er605-watch exits 3, its JSON has `overall:"unreachable"`. Still
   publish it — HA can alert on `unreachable` distinctly from `down` (router/power problem vs WAN).
5. **Debounce in automations** (`for: "00:01:00"`) so a brief blip doesn't spam notifications.

---

## 8. Manual steps on HA (point-and-click, one time)

1. **Settings → Add-ons → Add-on Store → Mosquitto broker → Install → Start.**
2. Create an MQTT user: add a Home Assistant user (Settings → People) **or** configure a
   user/pass in the Mosquitto add-on config (`logins:`). Put these in the publisher's MQTT env.
3. **Settings → Devices & Services → Add Integration → MQTT** → point at the add-on (usually
   auto-detected, `core-mosquitto:1883`).
4. After the publisher runs once, the **ER605 Router** device + entities appear automatically
   (Discovery). No YAML editing.

Verify end-to-end:
- On HA: **Settings → Devices & Services → MQTT → Configure → Listen to a topic** → `er605/#` →
  confirm the JSON arrives.
- On the publisher box: `mosquitto_sub -h $MQTT_HOST -u .. -P .. -t 'er605/#' -v`.

---

## 9. Example automations (put in README.md / HA)

Both WANs down → phone push (debounced):
```yaml
automation:
  - alias: "ER605 both WANs down"
    trigger:
      - platform: state
        entity_id: binary_sensor.both_wans_down
        to: "on"
        for: "00:01:00"
    action:
      - service: notify.mobile_app_yourphone
        data: { title: "🔴 Internet down", message: "Both ER605 WAN links are down." }
  - alias: "ER605 recovered"
    trigger:
      - platform: state
        entity_id: sensor.er605_wan
        to: "ok"
    action:
      - service: notify.mobile_app_yourphone
        data: { title: "🟢 Internet restored", message: "WAN links are back up." }
```
Other ideas: alert on a single WAN down (failover), on `unreachable` (router/power), on degraded
(packet loss); dashboard entities card; history/uptime via the recorder.

---

## 10. Execution checklist (do in this order)

- [ ] Gather prereqs (§2): Pi IP, MQTT user/pass, publisher box OS/init, interval.
- [ ] Install Mosquitto add-on + MQTT integration on HA (§8 steps 1–3).
- [ ] On the publisher box: install `expect`, `ssh`, `jq`, `mosquitto-clients`.
- [ ] Create `integrations/home-assistant/` files (§3).
- [ ] Write `er605-mqtt-publish.sh` (§4) with discovery (§5) + robustness (§7).
- [ ] Create `er605-mqtt.env` from the example; set MQTT_* (git-ignored).
- [ ] Test publish manually; verify with `mosquitto_sub` and HA "Listen to a topic".
- [ ] Confirm entities auto-created; check they go `unavailable` when publisher stopped (expire_after).
- [ ] Install + enable the systemd timer (§6).
- [ ] Add automations (§9); test by powering down a WAN (or temporarily blocking it).
- [ ] Update root README + CLAUDE.md to point at `integrations/home-assistant/`.

---

## 11. Open questions to resolve when starting

1. Publisher box exact **OS/init** (systemd vs cron vs NAS vs Docker)? → picks the scheduler.
2. Want **full mode** (RTT/loss graphs) too, or just `--fast` link status?
3. **MQTT Discovery** (recommended) or hand-written HA YAML sensors?
4. **TLS** on MQTT (8883) needed, or is the LAN trusted (1883)?
5. One combined "internet up/down" sensor enough, or per-WAN binary sensors + RTT sensors?
