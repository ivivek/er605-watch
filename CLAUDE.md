# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash tooling that SSHes into a **TP-Link Omada ER605** router, drives its
interactive Dropbear CLI, and reports dual-WAN status + connectivity. There is no
build/test framework — these are standalone scripts. Verified only on **ER605 v2.0,
firmware 2.3.0**; parsing is matched to that firmware's exact text output.

## Scripts

- **`er605-watch`** — the main tool (the repo's command). Reports per-WAN
  status/IP/gateway/DNS and pings each WAN's gateway + a public IP. Flags:
  `--trace`/`-t` (full check then a slow traceroute), `--trace-only` (traceroute but
  skip pings — WAN status from link state; `mode:"trace-only"`), `--fast`/`-f` (skip
  pings → link status only, ~3s), `--json`/`-j` (emit JSON on stdout, progress→stderr; needs `jq`).
  **Exit codes:** `0` all up · `1` one down · `2` both down · `3` router unreachable
  · `4` usage/config. These are an API — keep them stable for cron/alert consumers.
  Optional `WAN1_ISP`/`WAN2_ISP` (`.env`) add a friendly label per WAN — shown as
  e.g. "Airtel Fiber (WAN1)" in output and as each WAN's `isp` field in `--json`
  (falls back to `WAN1`/`WAN2`). The JSON shape is a contract — see §integrations.
- **`probe_cli.sh`** — dev tool. Dumps the *raw* output of arbitrary CLI commands
  using the older `sleep`-paced driver (+`sshpass`). Use it to discover the command
  grammar / output format on a new firmware before touching parsers.
- **`debug_expect.sh`** — dev tool. Times each step of an `expect` session to locate
  stalls.

## Running

```bash
cp .env.example .env && chmod 600 .env   # set ROUTER_IP, ROUTER_PASS
./er605-watch                            # ~13s
./er605-watch --trace                    # + traceroute (~30-60s; slow on dead hops)
ROUTER_IP=... RPASS=... ./probe_cli.sh "show arp" "show system-info"
ROUTER_IP=... RPASS=... ./debug_expect.sh
bash -n er605-watch                      # syntax check (only "test" available)
```

Config precedence (high→low): **CLI flag (`--host <ip>`, password arg) > inline env
var > `.env` file**. `er605-watch` uses `expect` (no `sshpass`); the two dev tools
still use `sshpass`. Requires `expect`, `ssh`, and (`sshpass` for the dev tools).

## The ER605 CLI — non-obvious constraints that shape all the code

Everything here exists to work around this device. Do not "simplify" these away:

1. **Dropbear offers only the legacy `ssh-rsa` host key.** Every ssh invocation
   needs `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa`, or
   modern OpenSSH refuses to connect.
2. **No SSH exec mode.** `ssh router "show arp"` does *not* run the command (prints a
   `Match mac success` banner and exits). The CLI must be driven interactively over a
   PTY (`ssh -tt`).
3. **Commands return non-zero exit codes even on success.** Never judge success by
   `$?` — judge by whether a prompt came back / SSH transport (255 = real failure).
4. **No readiness signal.** `er605-watch` uses `expect` and waits for the `#` prompt
   after each command (no blind `sleep`s). The legacy `probe_cli.sh` instead paces
   with `sleep`s, which is why it can truncate slow output (bump `DELAY=`).
5. **`enable` is required** to reach the privileged `#` prompt; the base `>` prompt
   only offers `help/exit/enable/disable`.
6. **No clean EOF on logout.** After `exit`, the router never sends EOF — `expect eof`
   would block the full timeout (~30s/session). `run_cli` sends `exit` then `close`s
   the connection from our side. Keep this; it's the single biggest perf factor.
7. **`ping`/`tracert` take only an IP** (extra args → "Too many parameters") and
   follow the routing table — they cannot be bound to a WAN. So per-WAN health is
   tested by pinging *each WAN's own gateway* (egresses only that link); a public IP
   tests overall internet via the active route.

## `er605-watch` internals

- **`run_cli "cmd" ...`** — the heart of it. An `expect` heredoc (`expect -f -`,
  config passed via `EXP_*`/`CLI_CMDS` env vars) that logs in, `enable`s, sends each
  command waiting on `#`, then `close`s. Returns the full raw session text. The
  `expect` blocks use the simple single-pattern form (`expect "#"`) — the multi-arg
  `expect { -re {..} {..} timeout {..} }` form mis-parses here, so don't reintroduce it.
- **Parsing** is screen-scraping: `extract "$RAW" "<cmd>"` slices the output block for
  one command (between its `#<cmd>` echo and the next prompt); `get_field "$block"
  "<label>"` pulls a value from the `Field.....Value` (dots/colon separator) format.
- **One vs two SSH logins:** if `WAN1_GW`/`WAN2_GW` are set, shows + pings run in one
  login; left blank (the default), gateways are auto-discovered from `show interface
  switchport`, costing a second login. Either way it warns on live-vs-config drift.
- **MAIN is gather → derive → render.** It collects raw output, parses WAN fields
  (`read_wan`, tab-delimited), derives per-WAN/internet state (`ping_state`) and the
  `OVERALL`/`EXIT` status, *then* renders **either** pretty (stdout) **or** JSON
  (built with `jq`, never string-concatenated). All progress goes through
  `progress()` → stderr so `--json` stdout stays pure. Add new data once in the
  gather/derive step; surface it in both renderers.

## Integrations (`integrations/`)

Optional front-ends that consume `er605-watch --json`; each is self-contained with
its own README and does **not** change the core driver. The `--json` shape is the
contract between them — **change it in one place, update all three** (+ the JSON
doc in the root README).

- **`home-assistant/`** — `er605-mqtt-publish.sh` runs `er605-watch --json` on a
  timer and publishes status + MQTT Discovery configs to a Mosquitto broker; HA
  auto-creates entities. Broker creds in git-ignored `er605-mqtt.env`. Robustness
  via `expire_after` (not LWT); systemd timer. Deployed live: a Raspberry Pi
  publisher → HAOS Mosquitto. Auth gotcha: the add-on `logins:` field is flaky —
  use a Home Assistant user.
- **`ubuntu-panel/`** — Python GTK AppIndicator tray icon (state-tinted SVG in
  `icons/`, plain-text IP-free dropdown, manual-only spinner). Runs `er605-watch`
  **directly** on the desktop. `install.sh` + GNOME autostart. Menu colour lives in
  the panel icon only (GTK3 menus drop packed images / override label colour).
- **`ubuntu-panel-mqtt/`** — same tray UI, but **subscribes** to the publisher's
  `er605/status` (paho-mqtt) instead of driving the router — no router creds on the
  desktop. Push-driven (no Refresh/Full check); shows connection state + reason.
  `mqtt-test.py` is a no-GUI CLI to debug the broker connection/creds/data.

## Conventions

- **No site-specific values in tracked files — IPs, passwords, gateways, MACs, real
  usernames, or hostnames.** This is a hard rule for *every* file in the repo, including
  the `integrations/` tree, docs, and code comments. Real values live only in git-ignored
  env files: router creds in repo-root `.env`; the HA integration's broker creds in
  `integrations/home-assistant/er605-mqtt.env` (both git-ignored — `.gitignore` matches
  `.env` exactly so `.env.example` stays tracked, and lists `er605-mqtt.env` explicitly).
  Tracked files carry only placeholders (`changeme`, `192.168.0.10`, `<PI_IP>`,
  `<user>`/`<pass>`). The history was deliberately rebuilt to be IP-free; keep it that way.
  **Before any commit, grep the staged diff for real IPs/passwords/MACs/`user@host`** and
  confirm only placeholders remain. (A generic project-name label like `er605` used as an
  example username is fine; a real account/host is not.)
- Commits are authored as `Vivek K <vivek.oss@linetra.com>` (the `ivivek` GitHub
  account). Remote `origin` pushes over **HTTPS** as `ivivek`; the local SSH key
  authenticates as a *different* account, so SSH push won't work for this repo.
- When adapting to other Omada gateways (ER7206/7212PC/8411): the driver carries over;
  expect to adjust `WAN*_PORT`, the switchport range, and possibly field labels —
  re-verify formats with `probe_cli.sh`. Switches/EAPs use a different CLI entirely.
