#!/usr/bin/env bash
# Shared secret-scanning logic for this repo's git hooks.
#
# Reads a unified diff (produced with `-U0`) on stdin, scans ADDED lines only,
# prints any findings to stderr, and exits non-zero if something looks like a
# real secret. Scanning only added lines means pre-existing content is never
# re-flagged — you pay only for what a commit/push actually introduces.
#
# Scope is THIS repo's threat model (see CLAUDE.md "Conventions"): no real
# private/site IPs, MACs, router/broker passwords, private keys, or generic
# high-entropy tokens in tracked files — only placeholders. Off-the-shelf
# scanners miss the low-entropy stuff (a LAN IP, a MAC), so the rules below are
# hand-tuned to what this project leaks.
#
# Escape hatches:
#   * `git commit --no-verify` / `git push --no-verify` skip hooks entirely.
#   * Add a literal substring to hooks/secret-allow.txt (one per line, '#'
#     comments allowed) to whitelist a specific value that trips a rule.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOW_FILE="$HOOK_DIR/secret-allow.txt"

# --- placeholder allowlist: values that legitimately appear in tracked files -
# Keep in sync with .env.example and the integrations' *.env.example files.
ALLOW_IPS=(0.0.0.0 8.8.8.8 192.168.0.1 192.168.0.10 10.0.0.1)
ALLOW_PASS_VALUES=(changeme yourpassword your-router-password yourbrokerpass pass ... …)

# Extra literals from the per-repo allow file (optional).
ALLOW_LITERALS=()
if [[ -f "$ALLOW_FILE" ]]; then
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        ALLOW_LITERALS+=("$_line")
    done < "$ALLOW_FILE"
fi

# True if $1 contains any whitelisted literal from secret-allow.txt.
literal_allowed() {
    local hay=$1 lit
    for lit in "${ALLOW_LITERALS[@]:-}"; do
        [[ -n "$lit" && "$hay" == *"$lit"* ]] && return 0
    done
    return 1
}

# True if $1 is one of the placeholder IPs we tolerate.
allowed_ip() {
    local ip=$1 a
    for a in "${ALLOW_IPS[@]}"; do [[ "$ip" == "$a" ]] && return 0; done
    return 1
}

# True if $1 is an RFC1918 / CGNAT (100.64/10) address — i.e. a site/LAN IP
# that would reveal the user's network. Public IPs (DNS, etc.) are not secrets
# here, so they pass.
private_ip() {
    local ip=$1 o1 o2
    IFS=. read -r o1 o2 _ _ <<<"$ip"
    [[ "$o1" =~ ^[0-9]+$ && "$o2" =~ ^[0-9]+$ ]] || return 1
    case "$o1" in
        10)  return 0 ;;
        192) [[ "$o2" == 168 ]] && return 0 ;;
        172) (( o2 >= 16 && o2 <= 31 )) && return 0 ;;
        100) (( o2 >= 64 && o2 <= 127 )) && return 0 ;;
    esac
    return 1
}

# Inspect one added line of content; echo a reason string per finding.
scan_content() {
    local content=$1 ips macs ip mac val

    literal_allowed "$content" && return 0

    # 1. Private / site IPv4 addresses (skip allowlisted placeholders).
    ips=$(grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<<"$content" 2>/dev/null) || true
    for ip in $ips; do
        allowed_ip "$ip" && continue
        private_ip "$ip" && echo "private/site IP address: $ip"
    done

    # 2. MAC addresses (none are legitimate in tracked files).
    macs=$(grep -oE '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' <<<"$content" 2>/dev/null) || true
    for mac in $macs; do
        echo "MAC address: $mac"
    done

    # 3. Password / secret / token assignments with a real literal value.
    val=""
    local matched=0
    shopt -s nocasematch
    if [[ "$content" =~ (PASS|PASSWD|PASSWORD|SECRET|TOKEN|API_?KEY)[A-Z_]*[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        val="${BASH_REMATCH[2]}"
        matched=1
    fi
    shopt -u nocasematch
    if (( matched )); then
        # Reduce to the first token: cut at the first whitespace, then ';'.
        val="${val%%[[:space:]]*}"
        val="${val%%;*}"
        # Strip one layer of surrounding quotes.
        val="${val#[\"\']}"; val="${val%[\"\']}"
        local ok=0
        [[ -z "$val" ]] && ok=1                       # empty
        [[ "$val" == \$* ]] && ok=1                   # $VAR / ${VAR} reference
        [[ "$val" == \(* ]] && ok=1                   # (bash array literal)
        [[ "$val" == *"<"*">"* ]] && ok=1             # <placeholder>
        local p
        for p in "${ALLOW_PASS_VALUES[@]}"; do [[ "$val" == "$p" ]] && ok=1; done
        (( ok )) || echo "hardcoded secret value: ${content#"${content%%[![:space:]]*}"}"
    fi

    # 4. PEM private key block.
    grep -qE -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' <<<"$content" \
        && echo "private key material"

    return 0
}

# Read a -U0 unified diff on stdin; emit "path<TAB>lineno<TAB>added-content".
diff_added_lines() {
    awk '
        /^\+\+\+ / { path=$0; sub(/^\+\+\+ (b\/)?/,"",path); next }
        /^@@ /     { h=$0; sub(/^.*\+/,"",h); sub(/[, ].*$/,"",h); ln=h+0; next }
        /^\+/      { print path "\t" ln "\t" substr($0,2); ln++; next }
    '
}

# Main: scan the diff on stdin. Returns 1 (and prints a report) if anything hit.
run_scan() {
    local found=0 path ln content reason
    while IFS=$'\t' read -r path ln content; do
        [[ "$path" == /dev/null ]] && continue
        while IFS= read -r reason; do
            [[ -z "$reason" ]] && continue
            if (( found == 0 )); then
                echo "✖ Possible secret(s) blocked — these must not be committed:" >&2
                echo >&2
                found=1
            fi
            printf '  %s:%s — %s\n' "$path" "$ln" "$reason" >&2
        done < <(scan_content "$content")
    done < <(diff_added_lines)

    if (( found )); then
        echo >&2
        echo "Tracked files may carry only placeholders (see CLAUDE.md)." >&2
        echo "Put real values in a git-ignored .env file instead." >&2
        echo "If this is a false positive, add the literal to hooks/secret-allow.txt," >&2
        echo "or bypass once with --no-verify (then double-check it really is safe)." >&2
        return 1
    fi
    return 0
}
