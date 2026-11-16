#!/usr/bin/env python3
"""NetRefresh for Linux servers: network watchdog with escalating repair, outage log and a 7-day text graph.

Headless, standard library only, Python 3.7+. Run it as a systemd service (see install.sh).
Resets need root, so `run`, `reset` and `reboot` must be started with sudo.
"""
import argparse
import csv
import datetime as dt
import json
import os
import random
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

DEFAULTS = {
    "daily_time": "06:15",        # HH:MM every day, or "" for no daily action
    "daily_action": "reset",      # "reset" = soft network reset, "reboot" = restart the whole server
    "check_interval": 10,         # seconds between health checks
    "ping_hosts": ["1.1.1.1", "8.8.8.8"],
    "dns_name": "example.com",    # looked up on the upstream DNS server to prove DNS works
    "watch_services": [],         # systemd units that must stay active, e.g. ["tailscaled", "ssh"]; restarted if not
    "reboot_last_resort": True,   # reboot if the network is still down after 15 min
    "ntfy_topic": "",             # phone alerts through ntfy.sh; the topic name is the only secret
    "data_dir": "/var/lib/netrefresh",
}
CONFIRM_FAILS = 3                 # failed checks in a row before it counts as an outage
SOFT_AT, HARD_AT, REBOOT_AT = 90, 300, 900   # seconds into an outage
REBOOT_COOLDOWN_H = 3             # never reboot twice within this many hours (last-resort reboots)
DAILY_REBOOT_GUARD_MIN = 10       # a daily reboot is skipped if the server rebooted this recently


def run(cmd, timeout=30):
    """Run a program, return (exit code, output). Never raises."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)


def ping(host, wait=1):
    return run(["ping", "-c", "1", "-W", str(wait), host], timeout=wait + 3)[0] == 0


def parse_default_route(text):
    """'default via 192.168.1.1 dev eth0 ...' -> ('192.168.1.1', 'eth0'); (None, None) if there is none."""
    for line in text.splitlines():
        p = line.split()
        if p[:1] == ["default"]:
            return (p[p.index("via") + 1] if "via" in p else None), (p[p.index("dev") + 1] if "dev" in p else None)
    return None, None


def default_route():
    return parse_default_route(run(["ip", "-4", "route", "show", "default"])[1])


def dns_servers():
    """Upstream resolvers. The 127.x stub of systemd-resolved is skipped: it caches and would hide a dead DNS."""
    for path in ("/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"):
        try:
            with open(path) as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        found = [l.split()[1] for l in lines if l.startswith("nameserver") and len(l.split()) > 1]
        found = [s for s in found if ":" not in s and not s.startswith("127.")]
        if found:
            return found
    return []


def dns_query_packet(name, qid):
    labels = b"".join(bytes([len(p)]) + p.encode("ascii") for p in name.rstrip(".").split("."))
    return struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + labels + b"\0" + struct.pack(">HH", 1, 1)


def dns_reply_ok(data, qid):
    if len(data) < 12:
        return False
    rid, flags, _, answers = struct.unpack(">HHHH", data[:8])
    return rid == qid and bool(flags & 0x8000) and (flags & 0xF) == 0 and answers > 0


def dns_ok(server, name, timeout=2.0):
    """Ask the DNS server directly over UDP, so no local cache can hide a failure."""
    qid = random.randrange(65536)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(dns_query_packet(name, qid), (server, 53))
        return dns_reply_ok(s.recvfrom(512)[0], qid)
    except OSError:
        return False
    finally:
        s.close()


def service_active(unit):
    return run(["systemctl", "is-active", "--quiet", unit])[0] == 0


def health(cfg):
    """'ok' | 'internet' | 'dns' | 'service:<unit>' (the first thing that is broken)."""
    if not any(ping(h) for h in cfg["ping_hosts"]):
        return "internet"
    servers = dns_servers()
    if servers:
        if not any(dns_ok(s, cfg["dns_name"]) for s in servers):
            return "dns"
    else:
        try:
            socket.gethostbyname(cfg["dns_name"])
        except OSError:
            return "dns"
    for unit in cfg["watch_services"]:
        if not service_active(unit):
            return "service:" + unit
    return "ok"


def diagnose(kind):
    """Say WHERE the break is, in plain words (this is the cause written to the log)."""
    gw, dev = default_route()
    if dev:
        try:
            with open("/sys/class/net/%s/operstate" % dev) as f:
                if f.read().strip() == "down":
                    return "Ethernet link down (cable/NIC/driver)"
        except OSError:
            pass
    if not gw:
        return "No default gateway (DHCP lease lost)"
    if not ping(gw):
        return "Router unreachable (LAN side)"
    if kind == "internet":
        return "Router OK but no internet (ISP/WAN drop or router reconnect)"
    if kind == "dns":
        return "Internet OK but DNS failing (router DNS)"
    if kind.startswith("service:"):
        return "Internet OK but service %s is not running (remote access)" % kind[8:]
    return "Unknown"


# ---------- repairs ----------
def network_manager():
    if shutil.which("systemctl"):
        if service_active("NetworkManager"):
            return "NetworkManager"
        if service_active("systemd-networkd"):
            return "systemd-networkd"
    return None


def renew(dev):
    mgr = network_manager()
    if mgr == "systemd-networkd" and shutil.which("networkctl"):
        run(["networkctl", "reconfigure", dev])
    elif mgr == "NetworkManager" and shutil.which("nmcli"):
        run(["nmcli", "device", "reapply", dev])


def bounce(dev, log):
    log("Bouncing interface %s" % dev)
    run(["ip", "link", "set", "dev", dev, "down"])
    time.sleep(2)
    run(["ip", "link", "set", "dev", dev, "up"])
    time.sleep(8)


def restart_unit(unit, log):
    log("Restarting %s" % unit)
    rc, out = run(["systemctl", "restart", unit], 60)
    if rc:
        log("  failed: %s" % out.strip())


def internet_up(cfg):
    return any(ping(h, 3) for h in cfg["ping_hosts"])


def soft_reset(cfg, log):
    log("SOFT reset: flush DNS, bounce the link, renew the lease")
    for cmd in (["resolvectl", "flush-caches"], ["systemd-resolve", "--flush-caches"]):
        if shutil.which(cmd[0]) and run(cmd)[0] == 0:
            break
    dev = default_route()[1]
    if dev:
        bounce(dev, log)
        renew(dev)
    for unit in cfg["watch_services"]:
        restart_unit(unit, log)
    log("Done. Internet: %s" % ("UP" if internet_up(cfg) else "still DOWN"))


def hard_reset(cfg, log):
    log("HARD reset: restart the network stack and resolver, renew the lease")
    mgr = network_manager()
    if mgr:
        restart_unit(mgr, log)
    if shutil.which("systemctl") and service_active("systemd-resolved"):
        restart_unit("systemd-resolved", log)
    time.sleep(8)
    dev = default_route()[1]
    if dev:
        bounce(dev, log)
        renew(dev)
    for unit in cfg["watch_services"]:
        restart_unit(unit, log)
    log("Done. Internet: %s" % ("UP" if internet_up(cfg) else "still DOWN"))


def reboot_server(why, log):
    log("REBOOTING in 1 minute: %s (cancel with: shutdown -c)" % why)
    run(["shutdown", "-r", "+1", "NetRefresh: " + why])


# ---------- log, outage history, alerts ----------
def notify(cfg, title, msg):
    topic = re.sub(r"[^A-Za-z0-9_-]", "", cfg.get("ntfy_topic", ""))
    if not topic:
        return
    try:
        req = urllib.request.Request("https://ntfy.sh/" + topic, data=msg.encode("utf-8"), headers={"Title": title})
        urllib.request.urlopen(req, timeout=6).close()
    except Exception:   # an alert must never break the watchdog
        pass


class Store:
    """outages.csv (Start,End,Cause,Fix), netrefresh.log and state.json in the data directory."""

    def __init__(self, data_dir):
        self.dir = data_dir
        os.makedirs(data_dir, exist_ok=True)
        self.csv = os.path.join(data_dir, "outages.csv")
        self.logfile = os.path.join(data_dir, "netrefresh.log")
        self.statefile = os.path.join(data_dir, "state.json")

    def load(self):
        rows = []
        if os.path.exists(self.csv):
            with open(self.csv, newline="") as f:
                for r in csv.DictReader(f):
                    rows.append({"start": dt.datetime.fromisoformat(r["Start"]),
                                 "end": dt.datetime.fromisoformat(r["End"]) if r["End"] else None,
                                 "cause": r["Cause"], "fix": r["Fix"]})
        return rows

    def save(self, rows):
        fd, tmp = tempfile.mkstemp(dir=self.dir)
        with os.fdopen(fd, "w", newline="") as f:
            w = csv.writer(f, quoting=csv.QUOTE_ALL)
            w.writerow(["Start", "End", "Cause", "Fix"])
            for r in rows:
                w.writerow([r["start"].isoformat(timespec="seconds"), r["end"].isoformat(timespec="seconds") if r["end"] else "", r["cause"], r["fix"]])
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.csv)   # atomic: a crash can never leave a half-written history

    def log(self, msg):
        line = "[%s] %s" % (dt.datetime.now().strftime("%d.%m %H:%M:%S"), msg)
        print(line, flush=True)
        try:
            with open(self.logfile, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass

    def last_reboot(self):
        try:
            with open(self.statefile) as f:
                return dt.datetime.fromisoformat(json.load(f)["last_reboot"])
        except (OSError, ValueError, KeyError):
            return dt.datetime.min

    def set_last_reboot(self, when):
        with open(self.statefile, "w") as f:
            json.dump({"last_reboot": when.isoformat(timespec="seconds")}, f)


def render_graph(rows, now, days=7):
    """One text row per day, 48 columns of 30 minutes. '#' = internet down, '~' = a watched service/remote tool down."""
    out = ["          " + "".join("%02d    " % h for h in range(0, 24, 3))]
    for i in range(days):
        day = dt.datetime.combine(now.date() - dt.timedelta(days=i), dt.time())
        cells = []
        for b in range(48):
            lo, hi = day + dt.timedelta(minutes=30 * b), day + dt.timedelta(minutes=30 * b + 30)
            mark = "."
            for r in rows:
                if r["start"] < hi and (r["end"] or now) > lo:
                    mark = "~" if "service " in r["cause"] else "#"
                    if mark == "#":
                        break
            cells.append(mark)
        out.append("%-10s%s" % (day.strftime("%a %d.%m"), "".join(cells)))
    out.append("# internet down   ~ remote service down   . ok   (one row per day, 30 minutes per character)")
    return "\n".join(out)


def summary(rows, now):
    wk = [r for r in rows if r["start"] > now - dt.timedelta(days=7)]
    mins = sum(((r["end"] or now) - r["start"]).total_seconds() for r in wk) / 60
    common = max(set(r["start"].hour for r in wk), key=[r["start"].hour for r in wk].count) if wk else None
    return "Last 7 days: %d drops, %d min down%s" % (len(wk), mins, ", most often around %02d:00" % common if common is not None else "")


def recent_table(rows, n=8):
    lines = ["%-12s %-8s %-62s %s" % ("Started", "Down", "Cause", "Fixed by")]
    for r in sorted(rows, key=lambda r: r["start"], reverse=True)[:n]:
        dur = "%d min" % ((r["end"] - r["start"]).total_seconds() // 60) if r["end"] else "ongoing"
        lines.append("%-12s %-8s %-62s %s" % (r["start"].strftime("%d.%m %H:%M"), dur, r["cause"][:62], r["fix"] or ("self-recovered" if r["end"] else "-")))
    return "\n".join(lines)


# ---------- the watchdog ----------
class Watchdog:
    """Each method that touches the system is separate, so the escalation logic can be tested with fakes."""

    def __init__(self, cfg, store):
        self.cfg, self.store = cfg, store
        self.rows = store.load()
        for r in self.rows:   # a row still open belongs to a previous run (daemon stopped or server rebooted mid-outage)
            if r["end"] is None:
                r["end"] = self.now()
                r["fix"] = r["fix"] if r["fix"] == "reboot" else "daemon restarted"
        store.save(self.rows)
        self.cur, self.stage, self.kind, self.fails, self.first_fail = None, 0, "", 0, None
        self.stop = False
        self.next_daily = self.compute_next(self.now())

    # --- things tests replace ---
    def now(self): return dt.datetime.now()
    def health(self): return health(self.cfg)
    def diagnose(self, kind): return diagnose(kind)
    def log(self, msg): self.store.log(msg)
    def alert(self, title, msg): notify(self.cfg, title, msg)
    def soft(self): soft_reset(self.cfg, self.log)
    def hard(self): hard_reset(self.cfg, self.log)
    def service(self, unit): restart_unit(unit, self.log)
    def reboot(self, why): reboot_server(why, self.log)

    def compute_next(self, now):
        t = self.cfg["daily_time"]
        if not t:
            return None
        hh, mm = (int(x) for x in t.split(":"))
        n = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
        return n if n > now else n + dt.timedelta(days=1)

    def tick(self):
        now, h = self.now(), self.health()
        if h == "ok":
            self.fails = 0
            if self.cur:
                c = self.cur
                c["end"] = now
                c["fix"] = c["fix"] or "self-recovered"
                self.store.save(self.rows)
                self.cur, self.stage = None, 0
                mins = int((c["end"] - c["start"]).total_seconds() // 60)
                self.log("Back UP after %d min. Cause: %s. Fixed by: %s" % (mins, c["cause"], c["fix"]))
                self.alert("NetRefresh: back UP", "Down %d min. Cause: %s. Fixed by: %s" % (mins, c["cause"], c["fix"]))
            return
        if self.fails == 0:
            self.first_fail = now
        self.fails += 1
        if self.fails >= CONFIRM_FAILS and not self.cur:
            self.kind = h
            self.cur = {"start": self.first_fail, "end": None, "cause": self.diagnose(h), "fix": ""}
            self.rows.append(self.cur)
            self.store.save(self.rows)
            self.log("DOWN since %s. Cause: %s" % (self.first_fail.strftime("%H:%M:%S"), self.cur["cause"]))
            self.alert("NetRefresh: DOWN", "Since %s. Cause: %s" % (self.first_fail.strftime("%H:%M:%S"), self.cur["cause"]))
        if self.cur:
            self.escalate(now)

    def escalate(self, now):
        """soft reset -> hard reset -> reboot, each once per outage. A broken service only gets restarted, never a reboot."""
        d = (now - self.cur["start"]).total_seconds()
        unit = self.kind[8:] if self.kind.startswith("service:") else None
        if self.stage < 1 and d >= SOFT_AT:
            self.stage, self.cur["fix"] = 1, ("restart " + unit if unit else "soft reset")
            self.store.save(self.rows)
            self.service(unit) if unit else self.soft()
        elif self.stage == 1 and d >= HARD_AT:
            self.stage, self.cur["fix"] = 2, ("restart " + unit if unit else "hard reset")
            self.store.save(self.rows)
            self.service(unit) if unit else self.hard()
        elif self.stage == 2 and d >= REBOOT_AT and not unit and self.cfg["reboot_last_resort"]:
            self.stage = 3
            if (now - self.store.last_reboot()).total_seconds() >= REBOOT_COOLDOWN_H * 3600:
                self.cur["fix"] = "reboot"
                self.store.save(self.rows)
                self.store.set_last_reboot(now)
                self.alert("NetRefresh: rebooting", "Network down 15 min even after resets: the server reboots in 1 minute.")
                self.reboot("network down 15 min")
            else:
                self.log("Still down, but rebooted less than %d h ago: not rebooting again" % REBOOT_COOLDOWN_H)

    def check_daily(self):
        now = self.now()
        if not self.next_daily or now < self.next_daily:
            return
        if self.cfg["daily_action"] == "reboot" and (now - self.store.last_reboot()).total_seconds() >= DAILY_REBOOT_GUARD_MIN * 60:
            self.store.set_last_reboot(now)
            self.alert("NetRefresh: restarting", "Scheduled daily restart: the server reboots in 1 minute.")
            self.reboot("scheduled daily restart")
        else:
            self.log("Scheduled daily reset")
            self.soft()
        self.next_daily = self.compute_next(now)

    def run_forever(self):
        self.log("Watching every %ss. Daily %s at %s." % (self.cfg["check_interval"], self.cfg["daily_action"], self.cfg["daily_time"] or "never"))
        try:
            with open("/proc/uptime") as f:
                if float(f.read().split()[0]) < 300:
                    self.alert("NetRefresh: server is back", "The server started and NetRefresh is running.")
        except (OSError, ValueError):
            pass
        while not self.stop:
            self.tick()
            self.check_daily()
            for _ in range(int(self.cfg["check_interval"])):
                if self.stop:
                    break
                time.sleep(1)


# ---------- command line ----------
def load_config(path, data_dir=None):
    cfg = dict(DEFAULTS)
    try:
        with open(path) as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    except PermissionError:
        pass   # a non-root user can still read status/graph from the data directory
    except ValueError as e:
        sys.exit("config %s is not valid JSON: %s" % (path, e))
    if data_dir:
        cfg["data_dir"] = data_dir
    if cfg["daily_time"] and not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", cfg["daily_time"]):
        sys.exit('daily_time must be "HH:MM" (24 hour) or ""')
    if cfg["daily_action"] not in ("reset", "reboot"):
        sys.exit('daily_action must be "reset" or "reboot"')
    return cfg


def need_root():
    if getattr(os, "geteuid", lambda: 0)() != 0:
        sys.exit("This needs root: run it with sudo.")


def main(argv=None):
    ap = argparse.ArgumentParser(description="NetRefresh for Linux servers")
    ap.add_argument("--config", default="/etc/netrefresh/config.json")
    ap.add_argument("--data-dir", help="override data_dir from the config")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="watch the network (what the systemd service runs)")
    sub.add_parser("status", help="check now and show recent outages")
    sub.add_parser("graph", help="7-day outage graph")
    r = sub.add_parser("reset", help="run a repair now")
    r.add_argument("level", choices=["soft", "hard"])
    rb = sub.add_parser("reboot", help="reboot the server in 1 minute (asks first)")
    rb.add_argument("--yes", action="store_true")
    sub.add_parser("notify-test", help="send a test phone alert")
    a = ap.parse_args(argv)
    cfg = load_config(a.config, a.data_dir)

    if a.cmd == "run":
        need_root()
        import fcntl   # only exists on Linux, so it is imported here and not at the top
        store = Store(cfg["data_dir"])
        lock = open(os.path.join(store.dir, ".lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit("NetRefresh is already running.")
        w = Watchdog(cfg, store)
        signal.signal(signal.SIGTERM, lambda *_: setattr(w, "stop", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(w, "stop", True))
        w.run_forever()
    elif a.cmd == "status":
        h = health(cfg)
        print("Health now: %s%s" % (h, "" if h == "ok" else " - " + diagnose(h)))
        rows = Store(cfg["data_dir"]).load()
        print(summary(rows, dt.datetime.now()) + "\n\n" + recent_table(rows))
    elif a.cmd == "graph":
        rows = Store(cfg["data_dir"]).load()
        now = dt.datetime.now()
        print(summary(rows, now) + "\n\n" + render_graph(rows, now))
    elif a.cmd == "reset":
        need_root()
        (soft_reset if a.level == "soft" else hard_reset)(cfg, print)
    elif a.cmd == "reboot":
        need_root()
        if not a.yes and input("Reboot this server in 1 minute? Type yes: ").strip().lower() != "yes":
            sys.exit("Cancelled.")
        reboot_server("manual test", print)
    elif a.cmd == "notify-test":
        notify(cfg, "NetRefresh test", "If you can read this, phone alerts work.")
        print("Sent (if a topic is set and the server can reach ntfy.sh).")


if __name__ == "__main__":
    main()
