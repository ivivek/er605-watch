# Git hooks — secret scanning

Hand-written, dependency-free git hooks that enforce this repo's hard rule:
**no real IPs, passwords, gateways, MACs, usernames, or hostnames in tracked
files — only placeholders** (see the "Conventions" section of `CLAUDE.md`).
They automate the "grep the staged diff before committing" step that rule
already asks for.

Plain `bash` + `git` + `grep` + `awk`. No `pre-commit` framework, no Python,
nothing to `pip install` — consistent with the rest of this repo.

## Install

```bash
./hooks/install.sh              # point git at hooks/ via core.hooksPath
./hooks/install.sh --uninstall  # revert to the default .git/hooks
```

`install.sh` sets `core.hooksPath=hooks`, so the hooks live in version control
and every clone uses the same ones after a single `install.sh` run. (It's a
local git config setting; each clone runs it once.)

## What runs when

| Hook | Fires on | Scans |
|------|----------|-------|
| `pre-commit` | `git commit` | the **staged** additions only (fast) |
| `pre-push`   | `git push`   | the **outgoing** commits — a backstop for anything committed with `--no-verify` or before install |

Both share the rules in `secret-scan.sh` (one place to edit). They scan **added
lines only**, so pre-existing content is never re-flagged — a commit pays only
for what it introduces.

## What it flags

- **Private / site IPv4** — `10/8`, `172.16/12`, `192.168/16`, and CGNAT
  `100.64/10` (carrier-grade NAT, e.g. Jio AirFiber). Public IPs (DNS, etc.) are
  not secrets here and pass. Allowlisted placeholders: `192.168.0.1`,
  `192.168.0.10`, `10.0.0.1`, `8.8.8.8`, `0.0.0.0`.
- **MAC addresses** — any `xx:xx:xx:xx:xx:xx`. None are legitimate in tracked
  files.
- **Hardcoded credentials** — `*PASS*=`, `*SECRET*=`, `*TOKEN*=`, `*API[_]KEY=`
  assignments whose value is a real literal. Skipped: empty values, `$VAR` /
  `${VAR}` references, `<placeholder>` forms, `...`/`…`, and the known
  placeholders (`changeme`, `yourpassword`, `your-router-password`, `pass`).
- **Private keys** — `-----BEGIN … PRIVATE KEY-----` blocks.

## Bypassing & false positives

- **One-off bypass:** `git commit --no-verify` / `git push --no-verify`.
- **Whitelist a value:** add the literal substring to `hooks/secret-allow.txt`
  (one per line). Any added line containing it is skipped. Keep that list short
  and reviewed — every entry is a hole in the net.

## Limits — read this

These are **local** hooks. `--no-verify` skips them, and a fresh clone that
never runs `install.sh` has no protection. They cut accidental leaks but are not
an enforcement boundary. For that, add a server-side layer:

- Turn on **GitHub Push Protection / Secret Scanning** for the repo.
- And/or run a scanner (e.g. `gitleaks`) in **CI** on pull requests.

And regardless of tooling: a credential that ever reached a remote is
compromised — **rotate it**, don't just rewrite history.
