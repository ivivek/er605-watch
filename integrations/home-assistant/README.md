# ER605 → Home Assistant (via MQTT)

Surface ER605 dual-WAN status in Home Assistant — phone alerts, dashboards,
history, and automations — without putting router credentials anywhere near HA.

See [`PLAN.md`](PLAN.md) for the full design rationale. This README is the
how-to.

## How it works

```
[always-on Linux box]  --SSH/expect-->  [ER605 router]
   er605-watch --fast --json
        | (systemd timer, ~60s)
        v  mosquitto_pub  (MQTT)
[Raspberry Pi / HAOS]
   Mosquitto add-on (broker)  <-- publisher connects here
   Home Assistant (MQTT)      --> auto-created entities --> automations/dashboard
```

HAOS can't host the `expect`-driven poller (no `expect`/`jq`, 60s command
timeout, non-persistent FS), so the poller runs on a **separate always-on box**
that can reach both the router and the Pi. It pushes status to the **Mosquitto
broker** on the Pi; HA subscribes and **auto-creates entities via MQTT
Discovery** (no YAML editing). Router creds stay on the publisher box.

## Files

| File | Purpose |
|---|---|
| `er605-mqtt-publish.sh` | Runs `er605-watch --json`, publishes status + Discovery to MQTT |
| `er605-mqtt.env.example` | MQTT settings template (copy to `er605-mqtt.env`, git-ignored) |
| `systemd/er605-mqtt.service` | oneshot unit that runs the publisher |
| `systemd/er605-mqtt.timer` | runs it every 60s |
| `PLAN.md` | design doc |

## Setup

### 1. On Home Assistant (one time, point-and-click)

1. **Settings → Add-ons → Add-on Store → Mosquitto broker → Install → Start.**
2. **Create an MQTT login — use a Home Assistant user (recommended).**
   **Settings → People → Users → Add user** (e.g. username `er605`, set a
   password, non-admin is fine, must be able to log in). The Mosquitto add-on
   authenticates HA users automatically — this Just Works.
   - Avoid the add-on's `logins:` field unless you know it well: it requires an
     **add-on restart** to take effect and **fails silently** on a YAML mistake
     (wrong indentation / missing `-`), surfacing only as `not authorised` on
     the publisher. The HA-user route sidesteps all of that.
   - Prefer a password of **letters/digits only** — `#` and other symbols are
     easy to mangle in the add-on YAML / UI.
3. **Settings → Devices & Services → Add Integration → MQTT** → point at the
   add-on (usually auto-detected as `core-mosquitto:1883`).

### 2. On the publisher box (the always-on Linux machine)

```bash
# clone/copy the repo somewhere stable, e.g. /opt/er605
sudo apt-get install expect openssh-client jq mosquitto-clients

# router creds (shared with er605-watch) — repo root
cp .env.example .env && chmod 600 .env      # set ROUTER_IP, ROUTER_PASS

# MQTT settings — this directory
cd integrations/home-assistant
cp er605-mqtt.env.example er605-mqtt.env && chmod 600 er605-mqtt.env
# set MQTT_HOST, MQTT_USER, MQTT_PASS
```
> `MQTT_HOST` is the **broker's** IP — i.e. your **HAOS box** running the
> Mosquitto add-on — *not* this publisher box. They're usually different
> machines (publisher reaches the router; broker lives with HA).

Test it once manually:

```bash
./er605-mqtt-publish.sh --full          # publish discovery + a full-mode status
```

Verify the messages land — on the publisher box:

```bash
mosquitto_sub -h <PI_IP> -u <user> -P <pass> -t 'er605/#' -v
```

…or in HA: **Settings → Devices & Services → MQTT → Configure → Listen to a
topic** → `er605/#`. The **ER605 Router** device and its entities should appear
automatically under Devices & Services.

### 3. Schedule it (systemd)

Edit `systemd/er605-mqtt.service` — set `ExecStart` to the real path and `User`
to the account that owns the repo (so it can read the git-ignored env files).
Append `--full` to the `ExecStart` if you want RTT graphs (see "Fast vs full"
below); the unit ships as `--fast` by default. Then:

```bash
sudo cp systemd/er605-mqtt.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now er605-mqtt.timer
journalctl -u er605-mqtt.service -f          # watch it run
```

**Non-systemd hosts:** use cron (`* * * * * /opt/er605/integrations/home-assistant/er605-mqtt-publish.sh`),
a NAS task scheduler, or a looping container (`while true; do ./er605-mqtt-publish.sh; sleep 60; done`).

## Entities created

All grouped under one **ER605 Router** device. Each has `expire_after` set
(default 180s ≈ 3× the interval): if the publisher dies, the entities go
**unavailable** instead of showing a stale `ok`.

| Entity | Type | Meaning |
|---|---|---|
| `sensor.er605_overall` | sensor | `ok` / `degraded` / `down` / `unreachable`; full status JSON in attributes |
| `binary_sensor.er605_wan1` | connectivity | WAN1 up/down |
| `binary_sensor.er605_wan2` | connectivity | WAN2 up/down |
| `binary_sensor.er605_both_down` | problem | both WANs down (internet out) |
| `binary_sensor.er605_unreachable` | problem | router itself unreachable (power/box) |
| `sensor.er605_wan1_rtt` | sensor (ms) | WAN1 gateway RTT — **full mode only** |
| `sensor.er605_wan2_rtt` | sensor (ms) | WAN2 gateway RTT — **full mode only** |
| `sensor.er605_internet_rtt` | sensor (ms) | public-target RTT — **full mode only** |

### Fast vs full mode

- **`--fast`** (default, ~3s): link status only. `up` comes from the switchport
  link state; RTT sensors stay `unknown`. Good for a 60s cadence.
- **`--full`** (~13s): also pings each WAN gateway + a public IP, populating the
  RTT sensors and packet-loss-based `degraded`. Heavier on the router — don't
  run it every minute. A common setup is fast every 60s plus a second timer
  running `--full` every ~300s (copy the units, change the cadence and add
  `--full` to the `ExecStart`).

## Example automations

Paste into **Settings → Automations → ⋮ → Edit in YAML**, fixing entity/notify
names. The `for:` debounce avoids alerting on a momentary blip.

```yaml
- alias: "ER605 both WANs down"
  trigger:
    - platform: state
      entity_id: binary_sensor.er605_both_down
      to: "on"
      for: "00:01:00"
  action:
    - service: notify.mobile_app_yourphone
      data:
        title: "🔴 Internet down"
        message: "Both ER605 WAN links are down."

- alias: "ER605 single WAN down (failover)"
  trigger:
    - platform: state
      entity_id: sensor.er605_overall
      to: "degraded"
      for: "00:01:00"
  action:
    - service: notify.mobile_app_yourphone
      data:
        title: "🟡 WAN failover"
        message: "One ER605 WAN is down — running on the other link."

- alias: "ER605 router unreachable"
  trigger:
    - platform: state
      entity_id: binary_sensor.er605_unreachable
      to: "on"
      for: "00:02:00"
  action:
    - service: notify.mobile_app_yourphone
      data:
        title: "⚫ Router unreachable"
        message: "Can't reach the ER605 — power or device problem?"

- alias: "ER605 recovered"
  trigger:
    - platform: state
      entity_id: sensor.er605_overall
      to: "ok"
  action:
    - service: notify.mobile_app_yourphone
      data:
        title: "🟢 Internet restored"
        message: "Both ER605 WAN links are back up."
```

## Troubleshooting

- **No entities appear:** confirm the MQTT integration is connected and the
  publisher ran without error (`journalctl -u er605-mqtt.service`). Use HA's
  "Listen to a topic" on `homeassistant/#` to see the Discovery configs.
- **Entities show `unavailable`:** the publisher hasn't posted within
  `expire_after`. Check the timer (`systemctl status er605-mqtt.timer`) and that
  `er605-watch` itself works (`./er605-watch --fast` from the publisher box).
- **`overall: unreachable`:** the router didn't answer — check `ROUTER_IP` /
  `ROUTER_PASS` and SSH reachability from the publisher box. The status is still
  published, so `binary_sensor.er605_unreachable` will fire.
- **`not authorised` / auth refused to broker:** the broker is reachable but
  rejected the login. If you set the user via the Mosquitto add-on's `logins:`
  field, that's the usual culprit — it needs an add-on **restart** and breaks
  silently on a YAML slip. **Fix: create a Home Assistant user instead**
  (Settings → People → Users) with the same name/password as `er605-mqtt.env`;
  the add-on authenticates HA users automatically. (A `CONNACK`/return-code `5`
  with the broker still answering = credential mismatch, not a network problem.)
  Also confirm the broker allows non-TLS on 1883, or set `MQTT_TLS=1`.
