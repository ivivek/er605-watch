#!/usr/bin/env bash
# Install the ER605 MQTT panel indicator: deps + GNOME autostart entry.
# Run as your normal desktop user (uses sudo only for apt).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/er605-indicator-mqtt.py"

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

if [[ ! -f "$HERE/er605-mqtt-panel.env" ]]; then
    echo "!! No er605-mqtt-panel.env yet — copy the example and set MQTT_HOST/USER/PASS:"
    echo "     cp '$HERE/er605-mqtt-panel.env.example' '$HERE/er605-mqtt-panel.env'"
fi

echo ">> installing autostart entry…"
AUTOSTART="$HOME/.config/autostart"
mkdir -p "$AUTOSTART"
sed "s#__INDICATOR_PATH__#$PY#" "$HERE/er605-indicator-mqtt.desktop" > "$AUTOSTART/er605-indicator-mqtt.desktop"
echo "   wrote $AUTOSTART/er605-indicator-mqtt.desktop"

cat <<EOF

Done. Starts automatically at next login. Start it now:
    python3 "$PY" &

Note: run EITHER this MQTT indicator OR the direct one (integrations/
ubuntu-panel), not both — two indicators would show two panel icons.
EOF
