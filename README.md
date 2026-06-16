# ER605 Dual-WAN Connectivity Checker

A pair of Bash scripts that log into a **TP-Link Omada ER605** router over SSH and
report the live status of both WAN links plus their connectivity.

Tested on **ER605 v2.0, firmware 2.3.0 Build 20250428**.

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
./check_wan.sh '<router-password>'              # ~13s
./check_wan.sh '<router-password>' --trace      # also run a traceroute (slow)
# or
ROUTER_PASS='<router-password>' ./check_wan.sh
```

What it does — all in **one SSH login** (`expect`-driven, waits on the `#` prompt):

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

Configurable at the top of the script: `ROUTER_IP`, `ROUTER_USER`, `ROUTER_PORT`,
`WAN1_PORT`, `WAN2_PORT`, `PING_PUBLIC`, and `WAN1_GW` / `WAN2_GW`.

**On the gateways (speed vs. dynamic):** `WAN1_GW` / `WAN2_GW` are hardcoded (to
your discovered values) so the whole check runs in a **single** SSH login. The
script still reads the *live* gateway from `show interface switchport` and prints
a `⚠ configured ≠ live` warning if your ISP changes one. Leave either gateway
**blank** to auto-discover it instead — at the cost of a second SSH login.

### `probe_cli.sh` — the CLI discovery / debug tool

A helper used to reverse-engineer the CLI. It opens a paced, privileged session
and dumps the **raw** output of whatever commands you pass, so you can inspect the
real text format before writing parsers.

```bash
export RPASS='<router-password>'
./probe_cli.sh                                   # runs a default set of show commands
./probe_cli.sh "show arp" "show system-info"     # probe specific commands
DELAY=12 ./probe_cli.sh "ping 8.8.8.8"           # bump per-command wait for slow commands
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
  shell history and process list. Prefer the `ROUTER_PASS` environment variable.
- **Speed.** A full run takes ~14s. Because `check_wan.sh` waits on the `#` prompt
  (via `expect`) instead of fixed `sleep`s, the time is essentially just the SSH
  logins plus the actual `ping` durations — there is no wasted blind waiting.
- **Firmware-specific.** Output parsing is matched to firmware 2.3.0's exact text
  format. A different firmware version may change field labels; use `probe_cli.sh`
  to re-check and adjust the parsers.
