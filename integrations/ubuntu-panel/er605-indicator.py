#!/usr/bin/env python3
# =============================================================
# ER605 dual-WAN status — Ubuntu top-panel (AppIndicator) tray icon.
#
# Runs `er605-watch --json` on a timer and shows a colored status dot in the
# GNOME panel with a dropdown of per-WAN details. Direct mode: it drives the
# router itself (no MQTT/broker needed); router creds come from the repo-root
# .env, same as er605-watch.
#
# Deps: python3-gi, gir1.2-ayatanaappindicator3-0.1 (or gir1.2-appindicator3),
#       plus er605-watch's own deps (expect, jq, ssh). See install.sh.
#
# Env knobs:
#   ER605_PANEL_INTERVAL  poll seconds (default 60)
#   ER605_WATCH           path to er605-watch (default: ../../er605-watch)
# =============================================================
import os
import json
import threading
import subprocess

import gi
gi.require_version("Gtk", "3.0")
# Prefer the maintained Ayatana fork; fall back to legacy AppIndicator3.
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator
from gi.repository import Gtk, GLib

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = os.environ.get("ER605_WATCH", os.path.realpath(os.path.join(HERE, "..", "..", "er605-watch")))
INTERVAL = max(15, int(os.environ.get("ER605_PANEL_INTERVAL", "60")))

# Panel icon (monochrome, theme-adaptive) + a colored emoji dot in the label so
# the state reads at a glance even where symbolic icons are all one color.
STATE_ICON = {
    "ok":          "network-transmit-receive-symbolic",
    "degraded":    "network-error-symbolic",
    "down":        "network-offline-symbolic",
    "unreachable": "network-wired-disconnected-symbolic",
    "unknown":     "network-idle-symbolic",
}
STATE_DOT = {"ok": "🟢", "degraded": "🟡", "down": "🔴", "unreachable": "⚫", "unknown": "…"}


class ER605Indicator:
    def __init__(self):
        self.ind = AppIndicator.Indicator.new(
            "er605-wan", STATE_ICON["unknown"],
            AppIndicator.IndicatorCategory.SYSTEM_SERVICES)
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("ER605 WAN status")
        self.ind.set_label("…", "er605")

        self.menu = Gtk.Menu()
        self.ind.set_menu(self.menu)
        self._busy = False
        self._render({"overall": "unknown", "_note": "starting…"})

        # First poll shortly after launch, then every INTERVAL.
        GLib.timeout_add(500, self._kick_fast_once)
        GLib.timeout_add_seconds(INTERVAL, self._tick)

    # ---- polling -------------------------------------------------
    def _kick_fast_once(self):
        self.refresh(full=False)
        return False  # one-shot

    def _tick(self):
        self.refresh(full=False)
        return True   # keep the periodic timer

    def refresh(self, full=False):
        if self._busy:
            return
        self._busy = True
        threading.Thread(target=self._worker, args=(full,), daemon=True).start()

    def _worker(self, full):
        cmd = [WATCH, "--json"] + ([] if full else ["--fast"])
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
            data = json.loads(p.stdout) if p.stdout.strip() else \
                {"overall": "unreachable", "error": "no output from er605-watch"}
        except subprocess.TimeoutExpired:
            data = {"overall": "unreachable", "error": "er605-watch timed out"}
        except Exception as e:
            data = {"overall": "unreachable", "error": f"{type(e).__name__}: {e}"}
        # Hand back to the GTK main thread.
        GLib.idle_add(self._render, data)
        GLib.idle_add(self._done)

    def _done(self):
        self._busy = False
        return False

    # ---- rendering -----------------------------------------------
    def _render(self, data):
        overall = data.get("overall", "unknown")
        dot = STATE_DOT.get(overall, "…")
        self.ind.set_icon_full(STATE_ICON.get(overall, STATE_ICON["unknown"]), f"ER605 {overall}")

        wans = data.get("wans") or []
        up = sum(1 for w in wans if w.get("up"))
        label = dot if not wans else f"{dot} {up}/{len(wans)}"
        self.ind.set_label(label, "er605")

        # Rebuild the dropdown from scratch each refresh.
        for child in self.menu.get_children():
            self.menu.remove(child)

        self._item(f"Overall: {overall.upper()}", bold=True)
        if data.get("error"):
            self._item(f"  ⚠ {data['error']}")
        if data.get("_note"):
            self._item(f"  {data['_note']}")

        for i, w in enumerate(wans):
            name = w.get("isp") or w.get("name") or f"WAN{i+1}"
            port = w.get("port", i + 1)
            state = "UP" if w.get("up") else (w.get("status") or "DOWN")
            self._sep()
            self._item(f"{name} (WAN{port}): {state}", bold=True)
            if w.get("ip"):
                self._item(f"  IP: {w['ip']}")
            if w.get("gateway"):
                self._item(f"  Gateway: {w['gateway']}")
            ping = w.get("ping")
            if ping:
                loss = ping.get("loss_pct")
                rtt = ping.get("rtt_ms")
                self._item(f"  Ping: {ping.get('state','?')}"
                           + (f"  {rtt}ms" if rtt is not None else "")
                           + (f"  {loss}% loss" if loss is not None else ""))

        inet = data.get("internet")
        if inet:
            self._sep()
            self._item(f"Internet → {inet.get('target','?')}: {inet.get('state','?')}"
                       + (f"  {inet.get('rtt_ms')}ms" if inet.get("rtt_ms") is not None else ""))

        ts = data.get("timestamp")
        if ts:
            self._sep()
            self._item(f"Updated: {ts.replace('T', ' ')[:19]}")

        self._sep()
        self._action("Refresh now", lambda _:(self.refresh(full=False)))
        self._action("Full check (ping/RTT)", lambda _:(self.refresh(full=True)))
        self._sep()
        self._action("Quit", lambda _: Gtk.main_quit())
        self.menu.show_all()
        return False  # for GLib.idle_add

    # ---- tiny menu helpers ---------------------------------------
    def _item(self, text, bold=False):
        it = Gtk.MenuItem(label=text)
        it.set_sensitive(False)
        if bold:
            lbl = it.get_child()
            if lbl:
                lbl.set_markup(f"<b>{GLib.markup_escape_text(text)}</b>")
        self.menu.append(it)

    def _action(self, text, cb):
        it = Gtk.MenuItem(label=text)
        it.connect("activate", cb)
        self.menu.append(it)

    def _sep(self):
        self.menu.append(Gtk.SeparatorMenuItem())


def main():
    ER605Indicator()
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
