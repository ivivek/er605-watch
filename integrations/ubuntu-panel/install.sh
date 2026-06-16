#!/usr/bin/env bash
# Install the ER605 panel indicator: deps + GNOME autostart entry.
# Run as your normal desktop user (it uses sudo only for apt).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/er605-indicator.py"

echo ">> installing dependencies (needs sudo for apt)…"
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    # PyGObject + an AppIndicator binding (prefer the maintained Ayatana fork).
    sudo apt-get install -y python3-gi gir1.2-gtk-3.0
    sudo apt-get install -y gir1.2-ayatanaappindicator3-0.1 \
        || sudo apt-get install -y gir1.2-appindicator3-0.1 \
        || { echo "!! could not install an AppIndicator binding"; exit 1; }
    # er605-watch's own deps (no-ops if already present).
    sudo apt-get install -y expect jq openssh-client
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
