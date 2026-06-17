#!/usr/bin/env python3
# =============================================================
# Standalone CLI to test the MQTT broker connection + data, using the SAME
# config as er605-indicator-mqtt.py (er605-mqtt-panel.env / env vars). No GTK.
#
# Usage:
#   python3 mqtt-test.py            # connect, print first status message, exit
#   python3 mqtt-test.py --follow   # keep printing messages until Ctrl+C
#   python3 mqtt-test.py --timeout 15
#
# Exit codes: 0 got data · 3 connect/auth failed · 4 connected but no data
#             · 2 missing dep/config
# =============================================================
import os
import sys
import json
import time

HERE = os.path.dirname(os.path.abspath(__file__))

try:
    import paho.mqtt.client as mqtt
except ImportError:
    sys.exit("ERROR: python3-paho-mqtt not installed.\n"
             "  sudo apt-get install python3-paho-mqtt")


def load_cfg():
    cfg = {}
    path = os.environ.get("ER605_MQTT_ENV", os.path.join(HERE, "er605-mqtt-panel.env"))
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip("'\"")
    else:
        print(f"(no env file at {path} — using env vars / defaults)")
    g = lambda k, d=None: os.environ.get(k, cfg.get(k, d))
    return {"host": g("MQTT_HOST"), "port": int(g("MQTT_PORT", "1883")),
            "user": g("MQTT_USER"), "pw": g("MQTT_PASS"),
            "base": g("MQTT_BASE", "er605"), "tls": g("MQTT_TLS", "0") == "1"}


RC = {0: "accepted", 1: "bad protocol version", 2: "client id rejected",
      3: "broker unavailable", 4: "bad username/password", 5: "not authorised"}

STATE = {"got_data": False, "connack": None}


def main():
    follow = "--follow" in sys.argv or "-f" in sys.argv
    timeout = 10
    if "--timeout" in sys.argv:
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1])

    cfg = load_cfg()
    if not cfg["host"]:
        sys.exit("ERROR: MQTT_HOST not set (er605-mqtt-panel.env or env var).")

    topic = f"{cfg['base']}/status"
    print(f"→ broker  : {cfg['host']}:{cfg['port']}  (TLS={'on' if cfg['tls'] else 'off'})")
    print(f"→ user    : {cfg['user'] or '(anonymous)'}  pass: {'set' if cfg['pw'] else '(none)'}")
    print(f"→ topic   : {topic}")
    print("→ connecting…")

    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1)
    except (AttributeError, TypeError):
        client = mqtt.Client()
    if cfg["user"]:
        client.username_pw_set(cfg["user"], cfg["pw"])
    if cfg["tls"]:
        client.tls_set()

    def on_connect(c, u, flags, rc):
        STATE["connack"] = rc
        if rc == 0:
            print("✓ connected — subscribing")
            c.subscribe(topic)
        else:
            print(f"✗ connection refused: {RC.get(int(rc), rc)} (code {rc})")

    def on_message(c, u, msg):
        STATE["got_data"] = True
        retained = " [retained]" if msg.retain else ""
        print(f"\n● message on {msg.topic}{retained}:")
        try:
            d = json.loads(msg.payload.decode())
            wans = " · ".join(f"{w.get('isp') or w.get('name')}={'up' if w.get('up') else 'DOWN'}"
                              for w in d.get("wans", []))
            print(f"    overall={d.get('overall')}  {wans}")
            print("    " + json.dumps(d, indent=2).replace("\n", "\n    "))
        except Exception:
            print("    " + msg.payload.decode(errors="replace"))
        if not follow:
            c.disconnect()

    client.on_connect = on_connect
    client.on_message = on_message

    try:
        client.connect(cfg["host"], cfg["port"], keepalive=60)
    except Exception as e:
        sys.exit(f"✗ could not reach broker: {e}")

    client.loop_start()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if STATE["connack"] not in (None, 0):
            client.loop_stop()
            sys.exit(3)                       # auth/connect rejected
        if STATE["got_data"] and not follow:
            break
        time.sleep(0.2)
    client.loop_stop()

    if STATE["connack"] is None:
        sys.exit("✗ no CONNACK within timeout — host/port/firewall? (exit 3)")
    if not STATE["got_data"]:
        print(f"\n⚠ connected, but no message on '{topic}' within {timeout}s.")
        print("  Is the publisher running and publishing retained? (exit 4)")
        sys.exit(4)
    print("\n✓ OK — connection and data both work.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
