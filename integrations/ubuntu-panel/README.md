# ER605 status in the Ubuntu top panel

A small **AppIndicator** tray icon that shows ER605 dual-WAN status in the GNOME
top panel: a custom transmit/receive glyph **tinted by state** (green ok · amber
degraded · red down · grey unreachable, from `icons/`), a hover tooltip with a
one-line summary, and a polished dropdown — a colored status dot per WAN next to
the **ISP name** and state, with IP / gateway / ping-RTT on a dim second line.

Unlike the [Home Assistant integration](../home-assistant/), this runs
**`er605-watch` directly** on your desktop — no broker needed. Router
credentials come from the repo-root `.env`, same as `er605-watch`.

```
[panel icon]  --runs-->  er605-watch --fast --json  --ssh/expect-->  [ER605]
     ^ every 60s (configurable)
```

## Requirements

- A desktop running **GNOME with AppIndicator support** — on Ubuntu this is the
  built-in "Ubuntu AppIndicators" extension (enabled by default). On vanilla
  GNOME, install/enable an AppIndicator extension first.
- This box must reach the router and have the repo's `.env` filled in
  (`ROUTER_IP`, `ROUTER_PASS`). Set `WAN1_ISP`/`WAN2_ISP` in `.env` to show ISP
  names instead of WAN1/WAN2.
- Deps (installed by `install.sh`): `python3-gi`, `gir1.2-gtk-3.0`,
  `gir1.2-ayatanaappindicator3-0.1` (or `gir1.2-appindicator3-0.1`), plus
  `expect`/`jq`/`ssh` for `er605-watch`.

## Install

```bash
cd integrations/ubuntu-panel
./install.sh                      # installs deps + a GNOME autostart entry
python3 er605-indicator.py &     # start now without logging out
```

It then starts automatically at every login. To remove autostart:
`rm ~/.config/autostart/er605-indicator.desktop`.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `ER605_PANEL_INTERVAL` | `60` | poll interval in seconds (min 15) |
| `ER605_WATCH` | `../../er605-watch` | path to the watcher script |

Set them before launch, e.g. `ER605_PANEL_INTERVAL=120 python3 er605-indicator.py &`.
To bake an interval into autostart, add it to the `Exec=` line in
`~/.config/autostart/er605-indicator.desktop` (e.g.
`Exec=env ER605_PANEL_INTERVAL=120 python3 /path/to/er605-indicator.py`).

## Menu actions

- **Refresh now** — re-run a fast check immediately.
- **Full check (ping/RTT)** — run `--full` once (pings each WAN gateway + a
  public IP), populating the per-WAN RTT/loss lines until the next periodic
  (fast) refresh overwrites them.
- **Quit** — stop the indicator (autostart still brings it back next login).

## Notes / troubleshooting

- **No icon appears:** confirm an AppIndicator extension is enabled
  (`gnome-extensions list | grep -i appindicator`), then re-login. Wayland and
  X11 both work via the extension.
- **Icon stuck on ⚫ / "unreachable":** `er605-watch --fast` itself can't reach
  the router from this box — test it directly and check `.env`.
- **Polling cost:** each fast poll is one SSH login (~3s); the default 60s is
  fine. "Full check" is heavier (pings) — it's manual, not on the timer.
- The indicator runs the watcher in a background thread, so the menu stays
  responsive during a poll.
