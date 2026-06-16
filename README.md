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
| 2 | **No exec mode.** Running `ssh router "show arp"` does **not** execute the command — the CLI ignores it and just prints a `Match mac success` banner, then closes. | One-shot commands silently return garbage. | Allocate a real PTY (`ssh -tt`) and feed commands over **stdin**, as if typing them interactively. |
| 3 | **Non-zero exit codes on success.** The CLI returns a non-zero exit status even when a command succeeds. | Scripts that check `$?` wrongly conclude "SSH failed". | Judge success by the SSH *transport* (exit 255 = real failure), not by the remote command's exit code. |
| 4 | **No readiness signal / no flow control.** The CLI gives no prompt-ready marker, and input sent too early is discarded. | Piping all commands at once truncates or drops output. | **Pace** the input with `sleep`s — wait for the prompt after login, after `enable`, and after each command. |
| 5 | **Privileged commands gated behind `enable`.** The base prompt (`>`) only offers `help/exit/enable/disable`. | `show ...` / `ping` don't exist until you elevate. | Send `enable` first to reach the `#` prompt before running anything useful. |
| 6 | **Password auth only (in practice).** Key auth is often not usable; login is via password. | Cannot script `ssh` non-interactively without help. | Use [`sshpass`](https://linux.die.net/man/1/sshpass) to supply the password. |
| 7 | **`ping` cannot be bound to a source interface.** The CLI `ping <ip>` follows the routing table only — there is no "ping via WAN2" option. | You can't directly test "internet over WAN2". | Ping **each WAN's own default gateway** (which egresses that specific link) for a true per-WAN health check; ping a public IP separately for overall internet. |
| 8 | **Limited command set.** `show interface switchport <1-5>` and `show interface vlan <id>` require parameters; commands like `show ip route` are not registered. | Generic networking commands don't exist. | Use only the verified command grammar (see `probe_cli.sh`). |

Because of #2 and #4, **every interaction is essentially screen-scraping a paced,
interactive terminal session** — not a clean request/response API.

---

## Scripts

### `check_wan.sh` — the dual-WAN status report

```bash
./check_wan.sh '<router-password>'
# or
ROUTER_PASS='<router-password>' ./check_wan.sh
```

What it does:

1. **Connects** with the host-key workaround + PTY + paced stdin, and runs
   `enable` to reach privileged mode.
2. **Session 1** — runs `show interface switchport 1`, `show interface switchport 2`,
   and `show arp`, then parses each WAN's:
   - Port name, VLAN type, Routing Interface **Status** (UP/DOWN)
   - Protocol (dhcp / pppoe / static)
   - IP address, **Default Gateway**, Primary DNS
   - The full ARP table is printed as-is.
3. **Session 2** — pings, with results parsed for packet loss and average RTT:
   - **Each WAN's default gateway** (read live from step 2, not hardcoded) — a
     genuine per-link health check, since gateway traffic egresses that interface.
   - A **public IP** (`8.8.8.8` by default) for overall internet reachability
     (this follows the active route / load-balance / failover).
4. Prints a colour-coded **summary** (ONLINE / DEGRADED / OFFLINE).

Configurable at the top of the script: `ROUTER_IP`, `ROUTER_USER`, `ROUTER_PORT`,
`WAN1_PORT`, `WAN2_PORT`, `PING_PUBLIC`. All IPs/gateways/DNS are read **live**
from the router — only the port numbers and the public test IP are fixed.

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
- `sshpass` — `sudo apt-get install sshpass`
- `ssh` (OpenSSH client)
- SSH enabled on the router (Omada: enable CLI/SSH access)

## Notes & caveats

- **Password handling.** Passing the password as a CLI argument leaves it in your
  shell history and process list. Prefer the `ROUTER_PASS` environment variable.
- **Speed.** A full run takes ~40s. Most of that is the fixed `sleep` pacing
  (especially the 12s-per-ping waits) made necessary by limitation #4 — there is
  no completion signal to wait on, so the script over-waits to avoid truncation.
- **Firmware-specific.** Output parsing is matched to firmware 2.3.0's exact text
  format. A different firmware version may change field labels; use `probe_cli.sh`
  to re-check and adjust the parsers.
