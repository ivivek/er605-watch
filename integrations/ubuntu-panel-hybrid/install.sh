#!/usr/bin/env bash
# Install the ER605 hybrid panel indicator: deps + GNOME autostart entry.
# Run as your normal desktop user (uses sudo only for apt).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/er605-indicator-hybrid.py"

echo ">> checking dependencies…"
if command -v apt-get >/dev/null 2>&1; then
    # Collect only what's actually missing, so sudo is invoked only if needed.
    need=()
    for pkg in python3-gi gir1.2-gtk-3.0 python3-paho-mqtt; do
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
