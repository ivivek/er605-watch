#!/usr/bin/env python3
# =============================================================
# ER605 dual-WAN status — Ubuntu top-panel (AppIndicator) tray icon.
#
# Runs `er605-watch --json` on a timer and shows a custom tinted status icon in
# the GNOME panel (green/amber/red/grey transmit-receive arrows) with a polished
# dropdown: per-WAN status-dot rows, IP/gateway/RTT, internet, last-updated.
# Direct mode — it drives the router itself; creds come from the repo-root .env.
#
# Deps: python3-gi, gir1.2-gtk-3.0, gir1.2-ayatanaappindicator3-0.1
#       (or gir1.2-appindicator3-0.1), plus er605-watch's expect/jq/ssh.
#
# Env knobs:
#   ER605_PANEL_INTERVAL  poll seconds (default 60, min 15)
#   ER605_WATCH           path to er605-watch (default: ../../er605-watch)
# =============================================================
import os
import json
import threading
import subprocess

import gi
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator
from gi.repository import Gtk, GLib

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(HERE, "icons")
WATCH = os.environ.get("ER605_WATCH", os.path.realpath(os.path.join(HERE, "..", "..", "er605-watch")))
INTERVAL = max(15, int(os.environ.get("ER605_PANEL_INTERVAL", "60")))

# overall state -> panel icon name (file icons/<name>.svg) + menu dot.
STATE_ICON = {"ok": "er605-ok", "degraded": "er605-degraded",
              "down": "er605-down", "unreachable": "er605-unreachable",
              "unknown": "er605-unreachable"}
STATE_DOT = {"ok": "dot-green", "degraded": "dot-amber",
             "down": "dot-red", "unreachable": "dot-grey", "unknown": "dot-grey"}


def esc(s):
    return GLib.markup_escape_text(str(s))


class ER605Indicator:
    def __init__(self):
        self.ind = AppIndicator.Indicator.new_with_path(
            "er605-wan", "er605-unreachable",
            AppIndicator.IndicatorCategory.SYSTEM_SERVICES, ICONS)
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("ER605 WAN status")
        self.ind.set_label("", "er605-wan")   # icon-only, no text in the bar

        self.menu = Gtk.Menu()
        self.ind.set_menu(self.menu)
        self._busy = False
        self._render({"overall": "unknown", "_note": "starting…"})

        GLib.timeout_add(500, self._kick_once)
        GLib.timeout_add_seconds(INTERVAL, self._tick)

    # ---- polling -------------------------------------------------
    def _kick_once(self):
        self.refresh(full=False)
        return False

    def _tick(self):
        self.refresh(full=False)
        return True

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
        GLib.idle_add(self._render, data)
        GLib.idle_add(self._done)

    def _done(self):
        self._busy = False
        return False

    # ---- icon/colour helpers -------------------------------------
    @staticmethod
    def _wan_dot(w):
        if not w.get("up"):
            return "dot-red"
        ping = w.get("ping")
        if ping and ping.get("state") == "degraded":
            return "dot-amber"
        return "dot-green"

    # ---- rendering -----------------------------------------------
    def _render(self, data):
        overall = data.get("overall", "unknown")
        self.ind.set_icon_full(STATE_ICON.get(overall, "er605-unreachable"), f"ER605 {overall}")

        wans = data.get("wans") or []
        up = sum(1 for w in wans if w.get("up"))
        if data.get("error"):
            self.ind.set_title(f"ER605: {overall} — {data['error']}")
        elif wans:
            self.ind.set_title(f"ER605: {overall.upper()} · {up}/{len(wans)} WANs up")
        else:
            self.ind.set_title(f"ER605: {overall}")

        for child in self.menu.get_children():
            self.menu.remove(child)

        # Header: overall state with a colour dot.
        self._info(STATE_DOT.get(overall, "dot-grey"),
                   f"<b>ER605 — {esc(overall.upper())}</b>")
        if data.get("error"):
            self._info(None, f"<span alpha='65%'>⚠ {esc(data['error'])}</span>")
        if data.get("_note"):
            self._info(None, f"<span alpha='55%'>{esc(data['_note'])}</span>")

        # Per-WAN rows: dot + two-line label (name/state, then dim details).
        if wans:
            self._sep()
        for i, w in enumerate(wans):
            name = w.get("isp") or w.get("name") or f"WAN{i + 1}"
            port = w.get("port", i + 1)
            state = "up" if w.get("up") else (w.get("status") or "down")
            bits = []
            if w.get("ip"):
                bits.append(esc(w["ip"]))
            if w.get("gateway"):
                bits.append("gw " + esc(w["gateway"]))
            ping = w.get("ping")
            if ping:
                rtt = ping.get("rtt_ms")
                loss = ping.get("loss_pct")
                if rtt is not None:
                    bits.append(f"{esc(rtt)} ms")
                if loss:
                    bits.append(f"{esc(loss)}% loss")
            primary = f"<b>{esc(name)} (WAN{esc(port)})</b>  {esc(state).upper()}"
            markup = primary
            if bits:
                markup += f"\n<span size='small' alpha='55%'>{' · '.join(bits)}</span>"
            self._info(self._wan_dot(w), markup)

        inet = data.get("internet")
        if inet:
            self._sep()
            extra = f" · {esc(inet.get('rtt_ms'))} ms" if inet.get("rtt_ms") is not None else ""
            self._info("dot-green" if inet.get("online") else "dot-red",
                       f"Internet → {esc(inet.get('target', '?'))}  "
                       f"<span alpha='70%'>{esc(inet.get('state', '?'))}{extra}</span>")

        ts = data.get("timestamp")
        if ts:
            self._sep()
            self._info(None, f"<span size='small' alpha='55%'>Updated {esc(ts.replace('T', ' ')[:19])}</span>")

        self._sep()
        self._action("view-refresh-symbolic", "Refresh now", lambda _: self.refresh(False))
        self._action("emblem-synchronizing-symbolic", "Full check (ping / RTT)", lambda _: self.refresh(True))
        self._sep()
        self._action("application-exit-symbolic", "Quit", lambda _: Gtk.main_quit())
        self.menu.show_all()
        return False

    # ---- menu-row builders ---------------------------------------
    def _icon_widget(self, icon):
        """icon: a dot-* name (file in icons/) or a themed *-symbolic name, or None."""
        if not icon:
            img = Gtk.Image()
            img.set_size_request(16, 16)      # keep text aligned with iconed rows
            return img
        path = os.path.join(ICONS, icon + ".svg")
        if os.path.exists(path):
            return Gtk.Image.new_from_file(path)
        return Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU)

    def _info(self, icon, markup):
        item = Gtk.MenuItem()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=9)
        box.pack_start(self._icon_widget(icon), False, False, 0)
        lbl = Gtk.Label(xalign=0.0)
        lbl.set_markup(markup)
        box.pack_start(lbl, True, True, 0)
        item.add(box)
        item.set_sensitive(False)
        self.menu.append(item)

    def _action(self, icon, text, cb):
        item = Gtk.MenuItem()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=9)
        box.pack_start(self._icon_widget(icon), False, False, 0)
        lbl = Gtk.Label(label=text, xalign=0.0)
        box.pack_start(lbl, True, True, 0)
        item.add(box)
        item.connect("activate", cb)
        self.menu.append(item)

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
