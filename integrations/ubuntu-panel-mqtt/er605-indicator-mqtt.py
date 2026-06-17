#!/usr/bin/env python3
# =============================================================
# ER605 dual-WAN status — Ubuntu top-panel tray icon, MQTT edition.
#
# Same look as integrations/ubuntu-panel, but instead of driving the router it
# SUBSCRIBES to the MQTT publisher (the er605/status topic the Pi publishes).
# Data is pushed, so there is no Refresh/Full check — the publisher decides the
# cadence; this just displays what arrives. Router credentials never touch this
# box; it only needs read access to the broker.
#
# Config: er605-mqtt-panel.env next to this script (MQTT_HOST/USER/PASS/...),
#         git-ignored. Env vars override the file.
# Deps: python3-gi, gir1.2-gtk-3.0, an AppIndicator binding, python3-paho-mqtt.
# =============================================================
import os
import json
import time
import threading

import gi
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator
from gi.repository import Gtk, GLib

import paho.mqtt.client as mqtt

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(HERE, "icons")

# overall state -> panel icon (file icons/<name>.svg). Broker-disconnected and
# stale both fall back to the grey "unreachable" icon (the menu text clarifies).
STATE_ICON = {"ok": "er605-ok", "degraded": "er605-degraded",
              "down": "er605-down", "unreachable": "er605-unreachable",
              "unknown": "er605-unreachable"}


def load_cfg():
    """Read KEY=VALUE lines from er605-mqtt-panel.env; env vars win."""
    cfg = {}
    path = os.environ.get("ER605_MQTT_ENV", os.path.join(HERE, "er605-mqtt-panel.env"))
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip("'\"")
    g = lambda k, d=None: os.environ.get(k, cfg.get(k, d))
    return {
        "host": g("MQTT_HOST"), "port": int(g("MQTT_PORT", "1883")),
        "user": g("MQTT_USER"), "pw": g("MQTT_PASS"),
        "base": g("MQTT_BASE", "er605"), "tls": g("MQTT_TLS", "0") == "1",
        "stale": int(g("ER605_STALE_SECS", "180")),
    }


def esc(s):
    return GLib.markup_escape_text(str(s))


class MqttIndicator:
    def __init__(self, cfg):
        self.cfg = cfg
        self.data = None
        self.connected = False
        self.reason = "connecting…"   # why we're not connected (shown in the menu)
        self.last_msg = 0.0          # monotonic time of last status message

        self.ind = AppIndicator.Indicator.new_with_path(
            "er605-wan-mqtt", "er605-unreachable",
            AppIndicator.IndicatorCategory.SYSTEM_SERVICES, ICONS)
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("ER605 WAN status (MQTT)")
        self.ind.set_label("", "er605-wan-mqtt")
        self.menu = Gtk.Menu()
        self.ind.set_menu(self.menu)
        self._render()

        self._setup_mqtt()
        GLib.timeout_add_seconds(30, self._check_stale)

    # ---- MQTT ----------------------------------------------------
    def _setup_mqtt(self):
        try:                              # paho 2.x needs the API-version arg
            self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1)
        except (AttributeError, TypeError):
            self.client = mqtt.Client()
        if self.cfg["user"]:
            self.client.username_pw_set(self.cfg["user"], self.cfg["pw"])
        if self.cfg["tls"]:
            self.client.tls_set()
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        # connect_async + loop_start → background thread that connects & retries.
        try:
            self.client.connect_async(self.cfg["host"], self.cfg["port"], keepalive=60)
            self.client.loop_start()
        except Exception as e:
            self.reason = f"setup error: {e}"

    # MQTT CONNACK codes → human reason (so the menu says *why* it's down).
    _RC = {0: "connected", 1: "bad protocol version", 2: "client id rejected",
           3: "broker unavailable", 4: "bad username/password", 5: "not authorised"}

    def _on_connect(self, client, userdata, flags, rc):
        self.reason = self._RC.get(int(rc), f"refused (code {rc})")
        if rc == 0:
            client.subscribe(f"{self.cfg['base']}/status")
        GLib.idle_add(self._set_connected, rc == 0)

    def _on_disconnect(self, client, userdata, rc):
        if rc != 0 and self.reason == "connected":
            self.reason = "connection lost"
        GLib.idle_add(self._set_connected, False)

    def _on_message(self, client, userdata, msg):
        try:
            data = json.loads(msg.payload.decode())
        except Exception:
            return
        GLib.idle_add(self._update, data)

    # ---- state transitions (main thread) -------------------------
    def _set_connected(self, ok):
        self.connected = ok
        self._render()
        return False

    def _update(self, data):
        self.data = data
        self.last_msg = time.monotonic()
        self._render()
        return False

    def _check_stale(self):
        # If we've had data but nothing recently, flag it (grey icon + note).
        self._render()
        return True

    # ---- rendering -----------------------------------------------
    def _age(self):
        return time.monotonic() - self.last_msg if self.last_msg else None

    def _render(self):
        data = self.data
        age = self._age()
        stale = age is not None and age > self.cfg["stale"]

        if not self.connected:
            overall, status_line = "unknown", f"MQTT: {self.reason}"
        elif data is None:
            overall, status_line = "unknown", "MQTT: connected — waiting for data"
        elif stale:
            overall, status_line = "unknown", f"MQTT: stale (no update {int(age)}s)"
        else:
            overall = data.get("overall", "unknown")
            status_line = "MQTT: connected"

        self.ind.set_icon_full(STATE_ICON.get(overall, "er605-unreachable"),
                               f"ER605 (MQTT): {overall}")
        wans = (data or {}).get("wans") or []
        up = sum(1 for w in wans if w.get("up"))
        self.ind.set_title(f"ER605 (MQTT): {overall.upper()}"
                           + (f" · {up}/{len(wans)} up" if wans else ""))

        for child in self.menu.get_children():
            self.menu.remove(child)

        self._info(f"<b>ER605 — {esc(overall.upper())}</b>")
        if data and data.get("error"):
            self._info(f"<span alpha='65%'>⚠ {esc(data['error'])}</span>")

        if data and wans:
            self._sep()
        for i, w in enumerate(wans):
            name = w.get("isp") or w.get("name") or f"WAN{i + 1}"
            port = w.get("port", i + 1)
            state = "up" if w.get("up") else (w.get("status") or "down")
            bits = []
            ping = w.get("ping")
            if ping:
                if ping.get("rtt_ms") is not None:
                    bits.append(f"{esc(ping['rtt_ms'])} ms")
                if ping.get("loss_pct"):
                    bits.append(f"{esc(ping['loss_pct'])}% loss")
            markup = f"<b>{esc(name)} (WAN{esc(port)})</b>  {esc(state).upper()}"
            if bits:
                markup += f"\n<span size='small' alpha='55%'>{' · '.join(bits)}</span>"
            self._info(markup)

        inet = (data or {}).get("internet")
        if inet:
            self._sep()
            extra = f" · {esc(inet.get('rtt_ms'))} ms" if inet.get("rtt_ms") is not None else ""
            self._info(f"Internet  <span alpha='70%'>{esc(inet.get('state', '?'))}{extra}</span>")

        self._sep()
        self._info(f"<span size='small' alpha='55%'>{esc(status_line)}</span>")
        if data and data.get("timestamp"):
            self._info(f"<span size='small' alpha='55%'>Updated "
                       f"{esc(data['timestamp'].replace('T', ' ')[:19])}</span>")

        self._sep()
        self._action("Reconnect", lambda _: self._reconnect())
        self._action("Quit", lambda _: self._quit())
        self.menu.show_all()
        return False

    def _reconnect(self):
        threading.Thread(target=lambda: self._safe(self.client.reconnect), daemon=True).start()

    @staticmethod
    def _safe(fn):
        try:
            fn()
        except Exception:
            pass

    def _quit(self):
        self._safe(self.client.loop_stop)
        Gtk.main_quit()

    # ---- menu-row builders ---------------------------------------
    def _info(self, markup):
        item = Gtk.MenuItem()
        lbl = Gtk.Label(xalign=0.0)
        lbl.set_markup(markup)
        item.add(lbl)
        self.menu.append(item)

    def _action(self, text, cb):
        item = Gtk.MenuItem(label=text)
        item.connect("activate", cb)
        self.menu.append(item)

    def _sep(self):
        self.menu.append(Gtk.SeparatorMenuItem())


def main():
    cfg = load_cfg()
    if not cfg["host"]:
        raise SystemExit("ERROR: MQTT_HOST not set — copy er605-mqtt-panel.env.example "
                         "to er605-mqtt-panel.env and fill it in.")
    MqttIndicator(cfg)
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
