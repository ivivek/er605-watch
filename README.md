# ER605 Dual-WAN Connectivity Checker

Bash scripts that log into a **TP-Link Omada ER605** router over SSH and report
the live status of both WAN links plus their connectivity — one checker plus two
CLI-wrangling dev tools.

Tested on **ER605 v2.0, firmware 2.3.0 Build 20250428**.

---

## Compatibility

Verified only on the hardware above — everything below is informed inference, not
tested. The project has two layers, with very different portability:

**The driver & techniques (broadly reusable).** The SSH workarounds aren't really
ER605-specific; they apply to a whole class of devices:

- **Legacy `ssh-rsa` host key** → re-enabled via `HostKeyAlgorithms=+ssh-rsa` —
  applies to almost any [Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html)-based
  device (embedded routers, switches, NAS, IoT).
- **No SSH "exec" mode** → PTY + `expect` prompt-detection — applies to most
  interactive-CLI gear (Cisco IOS, MikroTik, HPE/Aruba, many embedded CLIs).
- **`enable` → privileged `#` prompt**, **non-zero exit codes**, **no clean EOF on
  logout** (`close` instead of `expect eof`) — all common Cisco-style-CLI traits.
- **`probe_cli.sh`** as a "discover an unknown CLI's grammar" tool is device-agnostic.

**The commands & parsers (Omada-gateway-specific).** `show interface switchport
<1-5>`, the `Field.....Value` parsing, and the WAN/gateway logic are tied to the
Omada **gateway** firmware (and the 2.3.0 text format).

| Device class | Expectation |
|---|---|
| **ER605** (v2, fw 2.3.0) | ✅ Tested — works. |
| Other **Omada gateways/routers** — ER7206, ER7212PC, ER8411 | 🟡 Likely works with minor tweaks (same firmware lineage). Different port counts (adjust `WAN*_PORT` and the `1-5` switchport range); field labels may differ slightly — re-check with `probe_cli.sh`. |
| Other **ER605 firmware** versions | 🟡 Driver fine; parsers may need adjusting if labels changed. |
| **Omada switches** (TL-SG…) | ❌ Different, more Cisco-like CLI and command set — parsers won't fit (driver techniques still do). |
| **Omada EAPs** (access points) | ❌ Different CLI again. |
| **Older non-Omada SafeStream** routers (TL-ER6020/6120, R600VPN) | ❌ Different/older firmware; may not expose this CLI at all. |

Bottom line: on another **Omada gateway** expect most of it to work after small
config tweaks; on switches/APs reuse the *driver*, rewrite the *commands*.

---

## Configuration

Config comes from three sources, **highest precedence first**:

1. **CLI flags / positional args** — `--host <ip>`, `<password>`, `--trace`
2. **Inline environment variables** — `ROUTER_IP=… ROUTER_PASS=… ./check_wan.sh`
3. **`.env` file** next to the scripts — git-ignored, holds your site-specific values

No router IP or password is stored in the repo. Set up your local `.env` once:

```bash
cp .env.example .env
chmod 600 .env            # keep the password readable only by you
# edit .env: set ROUTER_IP and ROUTER_PASS (and optionally WAN1_GW/WAN2_GW, etc.)
```

`.env` (note: `.env.example` is the committed template; `.env` itself is
git-ignored — an *exact* match in `.gitignore`, not `.env*`, so the example stays
tracked):

```sh
ROUTER_IP=192.168.0.1
ROUTER_PASS=yourpassword
# optional: ROUTER_USER, ROUTER_PORT, WAN1_PORT, WAN2_PORT, PING_PUBLIC, WAN1_GW, WAN2_GW
```

With `.env` in place you can just run `./check_wan.sh`. Override ad-hoc without
touching the file:

```bash
./check_wan.sh --host 10.0.0.1 'pass'      # different router, this run only
ROUTER_IP=10.0.0.1 ./check_wan.sh          # via env var
```

The same `.env` is shared by `probe_cli.sh` and `debug_expect.sh`.

---

## Why this is harder than it looks — the ER605 CLI limitations

The ER605 does **not** expose a normal Linux/SSH environment. Its SSH service is
[Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html) fronting a small,
custom, menu-style CLI. Several things that work on a normal host fail here, and
the scripts are built specifically to work around them:

| # | Limitation | Consequence | Workaround used |
|---|-----------|-------------|-----------------|
| 1 | **Legacy host key only.** Dropbear offers only the `ssh-rsa` (SHA-1) host key, which modern OpenSSH disables by default. | `ssh` fails with *"no matching host key type found. Their offer: ssh-rsa"* and the script dies before doing anything. | Connect with `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa`. |
| 2 | **No exec mode.** Running `ssh router "show arp"` does **not** execute the command — the CLI ignores it and just prints a `Match mac success` banner, then closes. | One-shot commands silently return garbage. | Allocate a real PTY (`ssh -tt`) and feed commands interactively. |
| 3 | **Non-zero exit codes on success.** The CLI returns a non-zero exit status even when a command succeeds. | Scripts that check `$?` wrongly conclude "SSH failed". | Judge success by the SSH *transport* / by whether a prompt came back, not by the remote command's exit code. |
| 4 | **No readiness signal / no flow control.** The CLI gives no prompt-ready marker, and input sent too early is discarded. | Piping all commands at once truncates or drops output. | Drive the session with [`expect`](https://core.tcl-lang.org/expect/): send a command, then **wait for the `#` prompt to return** before sending the next. No blind `sleep`s — it runs as fast as the router responds. |
| 5 | **Privileged commands gated behind `enable`.** The base prompt (`>`) only offers `help/exit/enable/disable`. | `show ...` / `ping` don't exist until you elevate. | Send `enable` first to reach the `#` prompt before running anything useful. |
| 6 | **Password auth only (in practice).** Key auth is often not usable; login is via password. | Cannot script `ssh` non-interactively without help. | Let `expect` type the password at the prompt. |
| 7 | **No clean logout / EOF.** After `exit`, the router does not promptly send EOF; `expect eof` blocks for the full timeout (~30s per session). | A naive driver is dozens of seconds slower than the actual work. | Once all output is captured, `close` the connection from our side instead of waiting for EOF. |
| 8 | **`ping`/`tracert` cannot be bound to a source interface.** Both take only an IP (`ping <ip>` / `tracert <ip>`; extra args give *"Too many parameters"*) and follow the routing table — there is no "ping via WAN2" option. | You can't directly test "internet over WAN2"; a traceroute only shows the active path. | Ping **each WAN's own default gateway** (which egresses that specific link) for a true per-WAN health check; ping a public IP separately for overall internet. `tracert`'s hop 1 reveals which WAN the route used. |
| 9 | **Limited command set.** `show interface switchport <1-5>` and `show interface vlan <id>` require parameters; commands like `show ip route` are not registered. | Generic networking commands don't exist. | Use only the verified command grammar (see `probe_cli.sh`). |

Because of #2 and #4, **every interaction is essentially screen-scraping an
interactive terminal session** — not a clean request/response API. The scripts use
`expect` to make that reliable and fast.

---

## Scripts

### `check_wan.sh` — the dual-WAN status report

```bash
./check_wan.sh                                  # all from .env  (~13s)
./check_wan.sh '<router-password>'              # password as arg, rest from .env
./check_wan.sh --host <ip> '<router-password>'  # override the router IP
./check_wan.sh --trace                          # also run a traceroute (slow)
```

What it does (`expect`-driven — waits on the `#` prompt, no blind sleeps; one SSH
login if `WAN*_GW` are set, otherwise two — see the gateway note below):

1. **Connects** with the host-key workaround + PTY, types the password, and runs
   `enable` to reach privileged mode.
2. **`show interface switchport 1/2` + `show arp`** — parses each WAN's:
   - Port name, VLAN type, Routing Interface **Status** (UP/DOWN)
   - Protocol (dhcp / pppoe / static)
   - IP address, **Default Gateway**, Primary DNS
   - The full ARP table is printed as-is.
3. **Pings** (same session), parsed for packet loss and average RTT:
   - **Each WAN's default gateway** — a genuine per-link health check, since
     gateway traffic can only egress that interface.
   - A **public IP** (`8.8.8.8` by default) for overall internet reachability
     (this follows the active route / load-balance / failover).
4. Prints a colour-coded **summary** (ONLINE / DEGRADED / OFFLINE).
5. **`--trace` / `-t`** (optional) — appends a `tracert` to the public target.
   Useful, but **slow**: traceroute waits out a timeout on every unresponsive
   (`* * *`) hop, so a single trace can take ~30–60s. Hop 1 reveals which WAN
   the active route used.

Configurable via `.env` / env vars (see [Configuration](#configuration)):
`ROUTER_IP`, `ROUTER_USER`, `ROUTER_PORT`, `WAN1_PORT`, `WAN2_PORT`, `PING_PUBLIC`,
and `WAN1_GW` / `WAN2_GW`.

**On the gateways (dynamic vs. speed):** by default `WAN1_GW` / `WAN2_GW` are
**blank**, so the script auto-discovers each WAN's gateway live from
`show interface switchport` — nothing site-specific is needed, at the cost of a
second SSH login. **Optionally** set both (in `.env`) to your real gateways to run
everything in a **single** login (~1s faster); the script then still reads the
*live* gateway and prints a `⚠ configured ≠ live` warning if your ISP changes one.

### `probe_cli.sh` — the CLI discovery / debug tool

A helper used to reverse-engineer the CLI. It opens a paced, privileged session
and dumps the **raw** output of whatever commands you pass, so you can inspect the
real text format before writing parsers.

```bash
# reads ROUTER_IP from .env; password via RPASS (or ROUTER_PASS in .env)
export RPASS='<router-password>'
./probe_cli.sh                                   # runs a default set of show commands
./probe_cli.sh "show arp" "show system-info"     # probe specific commands
DELAY=12 ./probe_cli.sh "ping 8.8.8.8"           # bump per-command wait for slow commands
```

> `probe_cli.sh` uses the older `sleep`-paced driver (and `sshpass`) — it predates
> the `expect` rewrite, which is fine for a discovery tool where you read the raw
> dump anyway.

### `debug_expect.sh` — per-step timing probe

Diagnostic for the `expect` driver: runs a full session (login → `enable` →
a couple of `show`s → a ping → logout) and prints the **milliseconds spent on each
step**, so you can spot which `expect` is stalling. This is the tool that pinned
the ~30s-per-session `expect eof` stall down to the logout step.

```bash
ROUTER_IP=... RPASS='<router-password>' ./debug_expect.sh   # or set them in .env
```

---

## Requirements

- `bash`
- `expect` — `sudo apt-get install expect` (drives the interactive CLI; `check_wan.sh` types the password itself, so `sshpass` is **not** required)
- `ssh` (OpenSSH client)
- SSH enabled on the router (Omada: enable CLI/SSH access)

> Note: `probe_cli.sh` is the older `sleep`-paced helper and still uses
> [`sshpass`](https://linux.die.net/man/1/sshpass) — only needed if you use that
> debug tool.

## Notes & caveats

- **Password handling.** Passing the password as a CLI argument leaves it in your
  shell history and process list (`ps`). Prefer putting `ROUTER_PASS` in a
  `chmod 600` `.env` file, or an inline `ROUTER_PASS=… ` env var.
- **Speed.** A full run takes ~14s. Because `check_wan.sh` waits on the `#` prompt
  (via `expect`) instead of fixed `sleep`s, the time is essentially just the SSH
  logins plus the actual `ping` durations — there is no wasted blind waiting.
- **Firmware-specific.** Output parsing is matched to firmware 2.3.0's exact text
  format. A different firmware version may change field labels; use `probe_cli.sh`
  to re-check and adjust the parsers.
