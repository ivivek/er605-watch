# ER605 status in the Ubuntu top panel — MQTT edition

Same look as the [direct panel indicator](../ubuntu-panel/) — a state-tinted
transmit/receive icon and a plain-text, IP-free dropdown — but it gets its data
by **subscribing to the MQTT publisher** instead of driving the router itself.

```
[Pi publisher] --er605/status--> [MQTT broker] --(subscribe)--> [panel icon]
```

Use this variant when a publisher is already pushing status to a broker (see the
[Home Assistant integration](../home-assistant/)) and you'd rather not put router
credentials / `expect` on the desktop. The indicator only needs **read** access
to the broker.

## How it differs from the direct indicator

- **Push, not poll** — it updates the instant a message arrives (retained, so the
  last value shows immediately on connect). No local polling timer.
- **No Refresh / Full check** — the *publisher* controls fast/full cadence; the
  desktop just displays. The menu instead shows a **connection status** line and
  a **Reconnect** action.
- **Goes "stale" / "disconnected"** — if the broker drops or no message arrives
  for `ER605_STALE_SECS` (default 180s), the icon greys out and the menu says so.
- No router credentials on this box — only broker creds.

## Requirements

- GNOME with AppIndicator support (built-in on Ubuntu).
- Network path to the broker, and a Mosquitto user with read access to
  `<base>/status`.
- Deps (via `install.sh`): `python3-gi`, `gir1.2-gtk-3.0`,
  `gir1.2-ayatanaappindicator3-0.1` (or `-appindicator3-0.1`), `python3-paho-mqtt`.

## Install

```bash
cd integrations/ubuntu-panel-mqtt
cp er605-mqtt-panel.env.example er605-mqtt-panel.env && chmod 600 er605-mqtt-panel.env
# set MQTT_HOST (broker/HAOS IP), MQTT_USER, MQTT_PASS
./install.sh
python3 er605-indicator-mqtt.py &
```

> Run **either** this MQTT indicator **or** the direct one
> ([`../ubuntu-panel`](../ubuntu-panel/)) — running both shows two panel icons.

## Configuration

`er605-mqtt-panel.env` (git-ignored; env vars override it):

| Key | Default | Meaning |
|---|---|---|
| `MQTT_HOST` | — | broker IP (the HAOS box) — **required** |
| `MQTT_PORT` | `1883` | `8883` for TLS |
| `MQTT_USER` / `MQTT_PASS` | — | broker login (read access to `<base>/status`) |
| `MQTT_BASE` | `er605` | base topic; subscribes to `<base>/status` |
| `MQTT_TLS` | `0` | `1` to use TLS |
| `ER605_STALE_SECS` | `180` | no update for this long → show "stale" |

## Test the connection (CLI, no GUI)

`mqtt-test.py` uses the **same config** as the indicator and prints exactly
what's happening — connection result, auth, and the received data:

```bash
python3 mqtt-test.py            # connect, print the first status message, exit
python3 mqtt-test.py --follow   # keep printing messages until Ctrl+C
```

It tells you which layer is failing (auth vs network vs no data). Exit codes:
`0` data OK · `3` connect/auth failed · `4` connected but no message · `2`
missing dep/config. Run this first if the indicator shows "disconnected".

## Troubleshooting

- **"MQTT: disconnected — <reason>":** the menu now shows the reason
  (`not authorised`, `bad username/password`, `broker unavailable`, …). Run
  `python3 mqtt-test.py` for the full picture.
- **"connected — waiting for data":** connected, but no retained `er605/status`
  yet — confirm the publisher has run at least once (it publishes retained).
- **Auth refused:** the `MQTT_USER`/`MQTT_PASS` don't match a broker login. With
  the HA Mosquitto add-on, a Home Assistant user is the reliable choice.
- **No icon at all:** ensure an AppIndicator extension is enabled, then re-login.
