#!/usr/bin/env python3
# =============================================================
# ER605 dual-WAN status — Ubuntu top-panel (AppIndicator) tray icon.
#
# Runs `er605-watch --json` on a timer and shows a custom tinted status icon in
# the GNOME panel (green/amber/red/grey transmit-receive arrows) with a plain-text
# dropdown: per-WAN state + latency, internet, last-updated (no IPs shown).
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
# Panel icon per overall state (file icons/<name>.svg). The dropdown itself is
# plain text — colour lives only in the panel icon.
STATE_ICON = {"ok": "er605-ok", "degraded": "er605-degraded",
              "down": "er605-down", "unreachable": "er605-unreachable",
              "unknown": "er605-unreachable"}


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

        # Header: overall state.
        self._info(f"<b>ER605 — {esc(overall.upper())}</b>")
        if data.get("error"):
            self._info(f"<span alpha='65%'>⚠ {esc(data['error'])}</span>")
        if data.get("_note"):
            self._info(f"<span alpha='55%'>{esc(data['_note'])}</span>")

        # Per-WAN rows: name/state, then a dim details line.
        if wans:
            self._sep()
        for i, w in enumerate(wans):
            name = w.get("isp") or w.get("name") or f"WAN{i + 1}"
            port = w.get("port", i + 1)
            state = "up" if w.get("up") else (w.get("status") or "down")
            bits = []  # IPs intentionally omitted; just latency/loss
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
            self._info(markup)

        inet = data.get("internet")
        if inet:
            self._sep()
            extra = f" · {esc(inet.get('rtt_ms'))} ms" if inet.get("rtt_ms") is not None else ""
            self._info(f"Internet  <span alpha='70%'>{esc(inet.get('state', '?'))}{extra}</span>")

        ts = data.get("timestamp")
        if ts:
            self._sep()
            self._info(f"<span size='small' alpha='55%'>Updated {esc(ts.replace('T', ' ')[:19])}</span>")

        self._sep()
        self._action("Refresh now", lambda _: self.refresh(False))
        self._action("Full check (ping / RTT)", lambda _: self.refresh(True))
        self._sep()
        self._action("Quit", lambda _: Gtk.main_quit())
        self.menu.show_all()
        return False

    # ---- menu-row builders ---------------------------------------
    def _info(self, markup):
        item = Gtk.MenuItem()
        lbl = Gtk.Label(xalign=0.0)
        lbl.set_markup(markup)
        item.add(lbl)
        # Sensitive (so text isn't desaturated); no activate handler → clicking
        # these info rows is a harmless no-op.
        self.menu.append(item)

    def _action(self, text, cb):
        item = Gtk.MenuItem(label=text)
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
