#!/usr/bin/env bash
# Install the ER605 panel indicator: deps + GNOME autostart entry.
# Run as your normal desktop user (it uses sudo only for apt).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/er605-indicator.py"

echo ">> checking dependencies…"
if command -v apt-get >/dev/null 2>&1; then
    # Collect only what's actually missing, so sudo is invoked only if needed.
    # PyGObject + er605-watch's own deps.
    need=()
    for pkg in python3-gi gir1.2-gtk-3.0 expect jq openssh-client; do
        dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
    done
    # AppIndicator: either binding satisfies it (prefer the Ayatana fork if we
    # have to install). Only add one if neither is already present.
    if ! dpkg -s gir1.2-ayatanaappindicator3-0.1 >/dev/null 2>&1 \
        && ! dpkg -s gir1.2-appindicator3-0.1 >/dev/null 2>&1; then
        need+=(gir1.2-ayatanaappindicator3-0.1)
    fi

    if [[ ${#need[@]} -eq 0 ]]; then
        echo "   all dependencies present — skipping apt (no sudo needed)."
    else
        echo ">> installing missing deps (needs sudo for apt): ${need[*]}"
        sudo apt-get update -qq
        # Fall back to the older binding if the Ayatana one isn't in the repos.
        sudo apt-get install -y "${need[@]}" \
            || { [[ " ${need[*]} " == *" gir1.2-ayatanaappindicator3-0.1 "* ]] \
                 && sudo apt-get install -y "${need[@]/gir1.2-ayatanaappindicator3-0.1/gir1.2-appindicator3-0.1}"; } \
            || { echo "!! could not install dependencies: ${need[*]}"; exit 1; }
    fi
else
    echo "!! no apt-get — install manually: python3-gi, gir1.2-gtk-3.0,"
    echo "   gir1.2-ayatanaappindicator3-0.1 (or gir1.2-appindicator3-0.1), expect, jq"
    exit 1
fi

# Best-effort: the file ships executable, and autostart invokes python3
# explicitly (below), so this is just a convenience — ignore if we don't own it.
chmod +x "$PY" 2>/dev/null || echo ">> note: couldn't chmod $PY (not owner?) — fine, it runs via python3 anyway."

echo ">> installing autostart entry…"
AUTOSTART="$HOME/.config/autostart"
mkdir -p "$AUTOSTART"
sed "s#__INDICATOR_PATH__#$PY#" "$HERE/er605-indicator.desktop" > "$AUTOSTART/er605-indicator.desktop"
echo "   wrote $AUTOSTART/er605-indicator.desktop"

cat <<EOF

Done. The indicator will start automatically at your next login.

Start it now without logging out:
    python3 "$PY" &

Notes:
  - It runs er605-watch directly, so router creds come from the repo-root .env.
  - Poll interval: export ER605_PANEL_INTERVAL=120 before launch to change it.
  - On Ubuntu GNOME the tray icon is shown by the built-in AppIndicators
    extension (enabled by default). On vanilla GNOME, enable an AppIndicator
    extension first.
EOF
