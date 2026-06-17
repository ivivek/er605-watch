#!/usr/bin/env bash
# Install the ER605 hybrid panel indicator: deps + GNOME autostart entry.
# Run as your normal desktop user (uses sudo only for apt).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/er605-indicator-hybrid.py"

echo ">> installing dependencies (needs sudo for apt)…"
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y python3-gi gir1.2-gtk-3.0 python3-paho-mqtt
    sudo apt-get install -y gir1.2-ayatanaappindicator3-0.1 \
        || sudo apt-get install -y gir1.2-appindicator3-0.1 \
        || { echo "!! could not install an AppIndicator binding"; exit 1; }
else
    echo "!! no apt-get — install manually: python3-gi, gir1.2-gtk-3.0,"
    echo "   python3-paho-mqtt, gir1.2-ayatanaappindicator3-0.1 (or -appindicator3-0.1)"
    exit 1
fi

chmod +x "$PY" 2>/dev/null || echo ">> note: couldn't chmod $PY (not owner?) — runs via python3 anyway."

if [[ ! -f "$HERE/er605-hybrid.env" ]]; then
    echo "!! No er605-hybrid.env yet — copy the example and set MQTT_HOST/USER/PASS:"
    echo "     cp '$HERE/er605-hybrid.env.example' '$HERE/er605-hybrid.env'"
fi

if [[ ! -f "$HERE/../../.env" ]]; then
    echo "!! Note: the Traceroute action runs er605-watch, which needs router creds"
    echo "   in the repo-root .env. Status display works without it; the trace won't."
fi

echo ">> installing autostart entry…"
AUTOSTART="$HOME/.config/autostart"
mkdir -p "$AUTOSTART"
sed "s#__INDICATOR_PATH__#$PY#" "$HERE/er605-indicator-hybrid.desktop" > "$AUTOSTART/er605-indicator-hybrid.desktop"
echo "   wrote $AUTOSTART/er605-indicator-hybrid.desktop"

cat <<EOF

Done. Starts automatically at next login. Start it now:
    python3 "$PY" &

Note: run only ONE ER605 indicator (direct, mqtt, or this hybrid) — each adds
its own panel icon.
EOF
