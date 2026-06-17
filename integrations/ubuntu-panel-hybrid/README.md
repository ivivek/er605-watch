# ER605 status in the Ubuntu top panel — hybrid edition

A blend of the other two panels: it **displays** status by subscribing to the
MQTT publisher (like [`ubuntu-panel-mqtt`](../ubuntu-panel-mqtt/)), but adds an
on-demand **Traceroute** action that runs `er605-watch` directly in a terminal
(like the [direct panel](../ubuntu-panel/)).

```
[Pi publisher] --er605/status--> [broker] --(subscribe)--> [panel icon]   (display)
                                  [this box] --er605-watch --trace-only--> [terminal]  (on demand)
```

Use this when you want push-driven status with **no polling load on the router**,
but still want to fire off a live traceroute from the panel now and then.

## How it relates to the other two

| | direct (`ubuntu-panel`) | mqtt (`ubuntu-panel-mqtt`) | **hybrid (this)** |
|---|---|---|---|
| Status source | drives the router | subscribes to MQTT | subscribes to MQTT |
| Polls the router? | yes (~60s) | no | no |
| Router creds on this box? | yes | **no** | **only for Traceroute** |
| Refresh / Full check | yes | no | no |
| Traceroute in a terminal | yes | no | **yes** |

The status half is identical to the MQTT panel — push-driven (retained, so the
last value shows on connect), goes **stale**/**disconnected** with a grey icon and
a reason in the menu, and has a **Reconnect** action.

## Requirement for the Traceroute action

Unlike the pure-MQTT panel, the **Traceroute** menu item runs
`er605-watch --trace-only` on *this* machine, so the trace (and only the trace)
needs:

- `er605-watch` reachable — defaults to the repo root (`../../er605-watch`); set
  `ER605_WATCH` if the panel lives outside the checkout.
- Router credentials in the **repo-root `.env`** (er605-watch reads them) and its
  deps (`expect`, `ssh`).
- A terminal emulator (`gnome-terminal`/`konsole`/`tilix`/`xfce4-terminal`/`xterm`).

If any are missing, status display still works — the Traceroute action just shows
a dialog explaining what's absent. If you want **zero** router access on this box,
use [`ubuntu-panel-mqtt`](../ubuntu-panel-mqtt/) instead.

## Requirements (display)

- GNOME with AppIndicator support (built-in on Ubuntu).
- Network path to the broker, and a Mosquitto user with read access to
  `<base>/status`.
- Deps (via `install.sh`): `python3-gi`, `gir1.2-gtk-3.0`,
  `gir1.2-ayatanaappindicator3-0.1` (or `-appindicator3-0.1`), `python3-paho-mqtt`.

## Install

```bash
cd integrations/ubuntu-panel-hybrid
cp er605-hybrid.env.example er605-hybrid.env && chmod 600 er605-hybrid.env
# set MQTT_HOST (broker/HAOS IP), MQTT_USER, MQTT_PASS
./install.sh                 # deps + GNOME autostart entry
python3 er605-indicator-hybrid.py &   # start now (autostarts next login)
```

## Config (`er605-hybrid.env`, git-ignored)

| Key | Default | Meaning |
|---|---|---|
| `MQTT_HOST` | — | broker IP/host (**required**) |
| `MQTT_PORT` | `1883` | broker port (`8883` with TLS) |
| `MQTT_USER` / `MQTT_PASS` | — | broker creds (read access to `<base>/status`) |
| `MQTT_BASE` | `er605` | base topic; subscribes to `<base>/status` |
| `MQTT_TLS` | `0` | `1` to enable TLS |
| `ER605_STALE_SECS` | `180` | no update for this long → "stale" (≈3× publish interval) |
| `ER605_WATCH` | `../../er605-watch` | path to er605-watch for the Traceroute action |

Env vars override the file. Broker creds live only here (git-ignored); router
creds live only in the repo-root `.env` (also git-ignored).

## Notes

- Run only **one** ER605 indicator (direct, mqtt, or this hybrid) — each adds its
  own panel icon.
- Menu colour lives in the panel icon only (GTK3 menus drop packed image colour),
  matching the other two panels.
