#!/usr/bin/env python3
"""NetRefresh for Linux servers: network watchdog that repairs according to the CAUSE it finds, with outage log,
7-day text graph, ISP report, router smart-plug power-cycle, heartbeat and phone alerts.

Headless, standard library only, Python 3.7+. Run it as a systemd service (see install.sh).
Repairs need root, so `run`, `reset` and `reboot` must be started with sudo.
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
    "daily_action": "reset",      # "reset" = network reset, "reboot" = restart the whole server
    "check_interval": 10,         # seconds between health checks
    "ping_hosts": ["1.1.1.1", "8.8.8.8"],
    "dns_name": "example.com",    # looked up on the upstream DNS server to prove DNS works
    "watch_services": [],         # systemd units that must stay active, e.g. ["tailscaled", "ssh"]; restarted if not
    "reboot_last_resort": True,   # reboot if a LOCAL network fault lasts 15 min (never for ISP outages)
    "ntfy_topic": "",             # phone alerts through ntfy.sh; the topic name is the only secret
    "heartbeat_url": "",          # healthchecks.io-style URL pinged every 5 min; it alerts you when the pings stop
    "router_plug": {"type": "", "host": ""},   # type: shelly1 | shelly2 | tasmota; host: the plug's IP address
    "data_dir": "/var/lib/netrefresh",
}
CONFIRM_FAILS = 3                 # failed checks in a row before it counts as an outage
STAGES = (90, 300, 900)           # seconds into an outage at which each repair stage runs
# Which repair fits which cause. Nothing on this server can fix an ISP outage, so it never resets it or reboots for one.
PLAN = {
    "local": ("adapter restart", "device restart", "reboot"),
    "router": ("adapter restart", "router power-cycle", "reboot"),
    "isp": (None, "router power-cycle", None),
    "dns": ("flush DNS", "renew lease", None),
    "remote": ("restart service", "restart service", None),
}
REBOOT_COOLDOWN_H = 3             # never reboot twice within this many hours (last-resort reboots)
DAILY_REBOOT_GUARD_MIN = 10       # a daily reboot is skipped if the server rebooted this recently
PLUG_MAX_PER_DAY, PLUG_GAP_MIN = 3, 30
HEARTBEAT_EVERY = 300


def run(cmd, timeout=30):
    """Run a program, return (exit code, output). Never raises."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)


def tcp_ok(host, port, timeout=1.5):
    try:
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def ping(host, wait=1):
    """True if the host answers ping. Without a usable `ping` program (minimal images) a TCP connect is used instead:
    a missing tool must never look like an outage, or the watchdog would reset and reboot a healthy server."""
    if shutil.which("ping"):
        rc = run(["ping", "-c", "1", "-W", str(wait), host], timeout=wait + 3)[0]
        if rc in (0, 1):          # 0 = reply, 1 = no reply; anything else means ping itself failed
            return rc == 0
    return any(tcp_ok(host, p, wait) for p in (53, 443, 80))


def internet_up(cfg):
    """Ping first; some networks block ping, so a TCP connection to port 443 counts too."""
    hosts = cfg["ping_hosts"]
    return any(ping(h) for h in hosts) or any(tcp_ok(h, 443) for h in hosts)


def parse_default_route(text):
    """'default via 192.168.1.1 dev eth0 ...' -> ('192.168.1.1', 'eth0'); (None, None) if there is none."""
    for line in text.splitlines():
        p = line.split()
        if p[:1] == ["default"]:
            return (p[p.index("via") + 1] if "via" in p else None), (p[p.index("dev") + 1] if "dev" in p else None)
    return None, None


def default_route_text():
    return run(["ip", "-4", "route", "show", "default"])[1]


def default_route():
    return parse_default_route(default_route_text())


_last_dev = None
_last_route = None   # arguments for `ip route replace`, remembered while the network works


def current_dev():
    """The interface to repair: the default route's, else the last one seen working, else the first physical NIC.
    (When the link drops, the default route vanishes, which is exactly when the interface is needed.)"""
    global _last_dev
    dev = default_route()[1]
    if dev:
        _last_dev = dev
        return dev
    if _last_dev:
        return _last_dev
    try:
        for name in sorted(os.listdir("/sys/class/net")):
            if name != "lo" and os.path.exists("/sys/class/net/%s/device" % name):
                return name
    except OSError:
        pass
    return None


def route_args(text):
    """The default route from `ip route` output as arguments for `ip route replace`, or None."""
    gw, dev = parse_default_route(text)
    if not (gw and dev):
        return None
    line = next((l.split() for l in text.splitlines() if l.startswith("default")), [])
    return ["default", "via", gw, "dev", dev] + (["onlink"] if "onlink" in line else [])


def remember_route():
    global _last_route
    args = route_args(default_route_text())
    if args:
        _last_route = args


def restore_route(log):
    """Taking a link down deletes its routes. Without NetworkManager or systemd-networkd nothing adds the default route
    back, which would cut the server off; so put back the one remembered while the network worked."""
    if default_route()[0] or not _last_route:
        return
    log("Restoring the default route (%s)" % " ".join(_last_route))
    run(["ip", "route", "replace"] + _last_route)


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
    if not internet_up(cfg):
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
    current_dev()     # remember the working interface and default route while all is well
    remember_route()
    return "ok"


def neighbor_ok(gw):
    """True if the kernel has recently talked to the gateway (ARP/ND state): proves it is there even if it drops ping."""
    state = run(["ip", "neigh", "show", gw])[1].split()
    return bool(state) and state[-1] in ("REACHABLE", "STALE", "DELAY", "PROBE", "PERMANENT")


def diagnose(kind):
    """Say WHERE the break is, in plain words (this is the cause written to the history)."""
    gw, dev = default_route()
    if dev:
        try:
            with open("/sys/class/net/%s/operstate" % dev) as f:
                if f.read().strip() == "down":
                    return "Network link down (cable or adapter)"
        except OSError:
            pass
    if not gw:
        return "No default gateway (DHCP lease lost)"
    # Only an internet outage can blame the router. For dns/service kinds the internet answered a moment ago, and many
    # gateways (cloud VPCs, some routers) ignore ping, so asking them would give a false "router unreachable".
    if kind == "internet":
        if not (ping(gw) or neighbor_ok(gw)):
            return "Router unreachable (LAN side)"
        return "Router OK but no internet (ISP/WAN drop or router reconnect)"
    if kind == "dns":
        return "Internet OK but DNS failing (router DNS)"
    if kind.startswith("service:"):
        return "Internet OK but service %s is not running (remote access)" % kind[8:]
    return "Unknown"


def cause_class(cause):
    if "link down" in cause or cause.startswith("No default gateway"):
        return "local"
    if cause.startswith("Router unreachable"):
        return "router"
    if cause.startswith("Router OK but no internet"):
        return "isp"
    if "DNS failing" in cause:
        return "dns"
    if "(remote access)" in cause:
        return "remote"
    return "local"


# ---------- repairs ----------
def network_manager():
    if shutil.which("systemctl"):
        if service_active("NetworkManager"):
            return "NetworkManager"
        if service_active("systemd-networkd"):
            return "systemd-networkd"
    return None


def renew(dev, log):
    mgr = network_manager()
    if mgr == "systemd-networkd" and shutil.which("networkctl"):
        run(["networkctl", "reconfigure", dev])
    elif mgr == "NetworkManager" and shutil.which("nmcli"):
        run(["nmcli", "device", "reapply", dev])
    restore_route(log)


def ifupdown_manages(dev):
    """True if /etc/network/interfaces (Debian ifupdown) configures this interface."""
    paths = ["/etc/network/interfaces"]
    try:
        paths += [os.path.join("/etc/network/interfaces.d", n) for n in os.listdir("/etc/network/interfaces.d")]
    except OSError:
        pass
    for p in paths:
        try:
            with open(p) as f:
                if re.search(r"^\s*iface\s+%s\s" % re.escape(dev), f.read(), re.M):
                    return True
        except OSError:
            pass
    return False


def bounce(dev, log):
    if shutil.which("ifdown") and shutil.which("ifup") and ifupdown_manages(dev):
        log("Restarting interface %s with ifdown/ifup" % dev)
        run(["ifdown", dev], 60)
        run(["ifup", dev], 60)
    else:
        log("Restarting interface %s" % dev)
        run(["ip", "link", "set", "dev", dev, "down"])
        time.sleep(2)
        run(["ip", "link", "set", "dev", dev, "up"])
        time.sleep(8)
    restore_route(log)


def restart_unit(unit, log):
    log("Restarting %s" % unit)
    rc, out = run(["systemctl", "restart", unit], 60)
    if rc:
        log("  failed: %s" % out.strip())


def flush_dns(log):
    log("Flushing the DNS cache")
    for cmd in (["resolvectl", "flush-caches"], ["systemd-resolve", "--flush-caches"]):
        if shutil.which(cmd[0]) and run(cmd)[0] == 0:
            return


def soft_reset(cfg, log):
    """Adapter restart: flush DNS, restart the link, renew the lease, restart watched services."""
    log("Adapter restart: flush DNS, restart the link, renew the lease")
    flush_dns(log)
    dev = current_dev()
    if dev:
        bounce(dev, log)
        renew(dev, log)
    for unit in cfg["watch_services"]:
        restart_unit(unit, log)


def hard_reset(cfg, log):
    """Device restart: restart the network manager and resolver, then the link."""
    log("Device restart: restart the network stack and resolver, renew the lease")
    mgr = network_manager()
    if mgr:
        restart_unit(mgr, log)
    if shutil.which("systemctl") and service_active("systemd-resolved"):
        restart_unit("systemd-resolved", log)
    time.sleep(8)
    dev = current_dev()
    if dev:
        bounce(dev, log)
        renew(dev, log)
    for unit in cfg["watch_services"]:
        restart_unit(unit, log)


def reboot_server(why, log):
    log("REBOOTING in 1 minute: %s (cancel with: shutdown -c)" % why)
    run(["shutdown", "-r", "+1", "NetRefresh: " + why])


def plug_url(plug):
    """Every command makes the PLUG switch itself back on after 30 s, so the router comes back even if this server
    cannot reach the plug any more."""
    plug = plug or {}
    host = str(plug.get("host", ""))
    if not re.fullmatch(r"[A-Za-z0-9.-]+(:\d{1,5})?", host):
        return None
    return {
        "shelly1": "http://%s/relay/0?turn=off&timer=30" % host,
        "shelly2": "http://%s/rpc/Switch.Set?id=0&on=false&toggle_after=30" % host,
        "tasmota": "http://%s/cm?cmnd=Backlog%%20Power1%%20Off%%3BDelay%%20300%%3BPower1%%20On" % host,
    }.get(plug.get("type", ""))


def plug_cycle(cfg, log):
    url = plug_url(cfg.get("router_plug"))
    if not url:
        log("Router plug: no plug type or valid address set")
        return False
    p = cfg["router_plug"]
    log("Router power-cycle via the %s plug at %s (off 30 s, it switches itself back on)" % (p.get("type"), p.get("host")))
    try:
        urllib.request.urlopen(url, timeout=5).close()
        return True
    except Exception as e:
        log("  the plug did not answer: %s" % e)
        return False


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


def send_heartbeat(cfg):
    url = str(cfg.get("heartbeat_url", ""))
    if not re.fullmatch(r"https?://\S+", url):
        return
    try:
        urllib.request.urlopen(url, timeout=6).close()
    except Exception:
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
                    try:
                        rows.append({"start": dt.datetime.fromisoformat(r["Start"]),
                                     "end": dt.datetime.fromisoformat(r["End"]) if r["End"] else None,
                                     "cause": r["Cause"], "fix": r["Fix"]})
                    except (ValueError, KeyError, TypeError):
                        pass   # skip a damaged row instead of refusing to start
        return rows

    def _write(self, path, text):
        fd, tmp = tempfile.mkstemp(dir=self.dir)
        with os.fdopen(fd, "w", newline="") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)   # atomic: a crash can never leave half a file

    def save(self, rows):
        lines = [["Start", "End", "Cause", "Fix"]] + [[r["start"].isoformat(timespec="seconds"), r["end"].isoformat(timespec="seconds") if r["end"] else "", r["cause"], r["fix"]] for r in rows]
        import io
        buf = io.StringIO()
        csv.writer(buf, quoting=csv.QUOTE_ALL).writerows(lines)
        self._write(self.csv, buf.getvalue())

    def log(self, msg):
        line = "[%s] %s" % (dt.datetime.now().strftime("%d.%m %H:%M:%S"), msg)
        print(line, flush=True)
        try:
            if os.path.exists(self.logfile) and os.path.getsize(self.logfile) > 5 * 1024 * 1024:
                os.replace(self.logfile, self.logfile + ".1")   # the log never grows without end
            with open(self.logfile, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass

    def state(self):
        try:
            with open(self.statefile) as f:
                s = json.load(f)
        except (OSError, ValueError):
            s = {}
        out = {"last_reboot": dt.datetime.min, "plug_times": []}
        try:
            out["last_reboot"] = dt.datetime.fromisoformat(s.get("last_reboot", ""))
        except (ValueError, TypeError):
            pass
        for t in s.get("plug_times", []):
            try:
                out["plug_times"].append(dt.datetime.fromisoformat(t))
            except (ValueError, TypeError):
                pass
        return out

    def save_state(self, st):
        self._write(self.statefile, json.dumps({"last_reboot": st["last_reboot"].isoformat(timespec="seconds"),
                                                "plug_times": [t.isoformat(timespec="seconds") for t in st["plug_times"]]}))

    # kept for the daily-action code and the tests
    def last_reboot(self):
        return self.state()["last_reboot"]

    def set_last_reboot(self, when):
        st = self.state()
        st["last_reboot"] = when
        self.save_state(st)


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
                    mark = "~" if cause_class(r["cause"]) == "remote" else "#"
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


def daily_pattern(rows, now):
    """(hour, days) if drops started in the same hour on 3+ different days in the last 7, else None."""
    days_by_hour = {}
    for r in rows:
        if r["start"] > now - dt.timedelta(days=7):
            days_by_hour.setdefault(r["start"].hour, set()).add(r["start"].date())
    if not days_by_hour:
        return None
    hour, days = max(days_by_hour.items(), key=lambda kv: len(kv[1]))
    return (hour, len(days)) if len(days) >= 3 else None


def isp_report(rows, now, days=30):
    rows = sorted((r for r in rows if r["start"] > now - dt.timedelta(days=days)), key=lambda r: r["start"])
    mins = lambda r: ((r["end"] or now) - r["start"]).total_seconds() / 60
    isp = [r for r in rows if cause_class(r["cause"]) == "isp"]
    counts = {}
    for r in rows:
        counts[cause_class(r["cause"])] = counts.get(cause_class(r["cause"]), 0) + 1
    out = ["NetRefresh outage report",
           "Period: %s - %s (%d days)" % ((now - dt.timedelta(days=days)).strftime("%d.%m.%Y"), now.strftime("%d.%m.%Y"), days), "",
           "Internet outages while the home router itself was working (an ISP-side problem): %d, %d minutes in total, longest %d minutes."
           % (len(isp), sum(mins(r) for r in isp), max([mins(r) for r in isp] or [0]))]
    pat = daily_pattern(rows, now)
    if pat:
        out.append("Repeating pattern: drops on %d of the last 7 days around %02d:00." % (pat[1], pat[0]))
    out += ["All outages in the period: %d (%s)" % (len(rows), ", ".join("%s: %d" % kv for kv in sorted(counts.items()))), "",
            "ISP-side outages:", "Start              End                Minutes"]
    for r in isp:
        out.append("%-18s %-18s %7d" % (r["start"].strftime("%d.%m.%Y %H:%M"), r["end"].strftime("%d.%m.%Y %H:%M") if r["end"] else "ongoing", mins(r)))
    out += ["", "How this was measured: every 10 seconds the server pings 1.1.1.1 and 8.8.8.8 and tries a TCP connection to port 443. "
                "Three failed checks in a row (about 30 s) count as an outage. \"Router working\" means the router answered on the local "
                "network (ping or ARP) during the outage."]
    return "\n".join(out)


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
                r["fix"] = r["fix"] if r["fix"] == "reboot" else "watchdog restarted"
        store.save(self.rows)
        self.cur, self.stage, self.kind, self.fails, self.first_fail = None, 0, "", 0, None
        self.last_beat = dt.datetime.min
        self.stop = False
        self.next_daily = self.compute_next(self.now())

    # --- things tests replace ---
    def now(self): return dt.datetime.now()
    def health(self): return health(self.cfg)
    def diagnose(self, kind): return diagnose(kind)
    def log(self, msg): self.store.log(msg)
    def alert(self, title, msg): notify(self.cfg, title, msg)
    def beat(self): send_heartbeat(self.cfg)
    def internet(self): return internet_up(self.cfg)
    def soft(self): soft_reset(self.cfg, self.log)
    def reboot(self, why): reboot_server(why, self.log)

    def act(self, action, unit=None):
        """Carry out one repair. Returns True if it was done."""
        if action == "adapter restart":
            soft_reset(self.cfg, self.log)
        elif action == "device restart":
            hard_reset(self.cfg, self.log)
        elif action == "flush DNS":
            flush_dns(self.log)
        elif action == "renew lease":
            dev = current_dev()
            if dev:
                self.log("Renewing the lease on %s" % dev)
                renew(dev, self.log)
        elif action == "restart service":
            restart_unit(unit, self.log)
        elif action == "router power-cycle":
            return plug_cycle(self.cfg, self.log)
        elif action == "reboot":
            self.reboot("network down 15 min")
        return True

    def compute_next(self, now):
        t = self.cfg["daily_time"]
        if not t:
            return None
        hh, mm = (int(x) for x in t.split(":"))
        n = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
        return n if n > now else n + dt.timedelta(days=1)

    def reboot_allowed(self, now):
        return self.cfg["reboot_last_resort"] and (now - self.store.last_reboot()).total_seconds() >= REBOOT_COOLDOWN_H * 3600

    def plug_allowed(self, now):
        """At most 3 power-cycles a day, 30 min apart: never a router reboot loop."""
        if not plug_url(self.cfg.get("router_plug")):
            return False
        recent = [t for t in self.store.state()["plug_times"] if (now - t).total_seconds() < 86400]
        return len(recent) < PLUG_MAX_PER_DAY and not any((now - t).total_seconds() < PLUG_GAP_MIN * 60 for t in recent)

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
            if (now - self.last_beat).total_seconds() >= HEARTBEAT_EVERY:
                self.last_beat = now
                self.beat()
            return
        if self.fails == 0:
            self.first_fail = now
        self.fails += 1
        if self.fails >= CONFIRM_FAILS and not self.cur:
            self.kind = h
            self.cur = {"start": self.first_fail, "end": None, "cause": self.diagnose(h), "fix": ""}
            self.stage = 0
            self.rows.append(self.cur)
            self.store.save(self.rows)
            self.log("DOWN since %s. Cause: %s" % (self.first_fail.strftime("%H:%M:%S"), self.cur["cause"]))
            self.alert("NetRefresh: DOWN", "Since %s. Cause: %s" % (self.first_fail.strftime("%H:%M:%S"), self.cur["cause"]))
        if self.cur:
            self.escalate(now, h)

    def escalate(self, now, h):
        """One repair per stage, chosen by the cause found at that moment (the cause can change during an outage)."""
        if self.stage >= len(STAGES) or (now - self.cur["start"]).total_seconds() < STAGES[self.stage]:
            return
        cls = cause_class(self.diagnose(h))
        action = PLAN[cls][self.stage]
        self.stage += 1
        if action == "router power-cycle" and not self.plug_allowed(now):
            action = "device restart" if cls == "router" else None   # no plug set up, or used up for today
        if action == "reboot" and not self.reboot_allowed(now):
            self.log("Still down, but rebooted less than %d h ago: not rebooting again" % REBOOT_COOLDOWN_H if self.cfg["reboot_last_resort"]
                     else "Still down; the last-resort reboot is switched off")
            action = None
        if not action:
            if cls == "isp" and self.stage == 1:
                self.log("Waiting: the router works but the internet does not: an ISP/WAN outage that nothing on this server can fix (it is counted in the ISP report)")
            return
        self.cur["fix"] = action if action != "restart service" else "restart " + h[8:]
        self.store.save(self.rows)
        if action == "reboot":
            self.store.set_last_reboot(now)
            self.alert("NetRefresh: rebooting", "A local network fault lasted 15 min even after repairs: the server reboots in 1 minute.")
            self.act(action)
            return
        if action == "router power-cycle":
            st = self.store.state()
            st["plug_times"].append(now)
            self.store.save_state(st)
        self.act(action, h[8:] if h.startswith("service:") else None)
        self.log("Done (%s). Internet: %s" % (action, "UP" if self.internet() else "still DOWN"))

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
                if float(f.read().split()[0]) < 600:
                    self.alert("NetRefresh: server is back", "The server started and NetRefresh is watching again.")
        except (OSError, ValueError):
            pass
        while not self.stop:
            try:
                self.tick()
                self.check_daily()
            except Exception as e:   # the watchdog must outlive any single failed check
                self.log("Internal error (continuing): %r" % (e,))
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
        pass   # a non-root user can still read status/graph/report from the data directory
    except ValueError as e:
        sys.exit("config %s is not valid JSON: %s" % (path, e))
    if data_dir:
        cfg["data_dir"] = data_dir
    if cfg["daily_time"] and not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", cfg["daily_time"]):
        sys.exit('daily_time must be "HH:MM" (24 hour) or ""')
    if cfg["daily_action"] not in ("reset", "reboot"):
        sys.exit('daily_action must be "reset" or "reboot"')
    plug = cfg.get("router_plug") or {}
    if plug.get("type") and not plug_url(plug):
        sys.exit('router_plug needs "type" shelly1, shelly2 or tasmota and "host" set to its IP address')
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
    rp = sub.add_parser("report", help="outage report for your ISP")
    rp.add_argument("--days", type=int, default=30)
    r = sub.add_parser("reset", help="run a repair now")
    r.add_argument("level", choices=["soft", "hard"])
    rb = sub.add_parser("reboot", help="reboot the server in 1 minute (asks first)")
    rb.add_argument("--yes", action="store_true")
    sub.add_parser("plug-test", help="power-cycle the router through the smart plug (asks first)")
    sub.add_parser("notify-test", help="send a test phone alert and a heartbeat")
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
    elif a.cmd == "report":
        print(isp_report(Store(cfg["data_dir"]).load(), dt.datetime.now(), a.days))
    elif a.cmd == "reset":
        need_root()
        (soft_reset if a.level == "soft" else hard_reset)(cfg, print)
        print("Internet: %s" % ("UP" if internet_up(cfg) else "still DOWN"))
    elif a.cmd == "reboot":
        need_root()
        if not a.yes and input("Reboot this server in 1 minute? Type yes: ").strip().lower() != "yes":
            sys.exit("Cancelled.")
        reboot_server("manual test", print)
    elif a.cmd == "plug-test":
        if not plug_url(cfg.get("router_plug")):
            sys.exit("Set router_plug in the config first.")
        if input("Switch the router off for 30 s (internet gone for 2-3 min)? Type yes: ").strip().lower() != "yes":
            sys.exit("Cancelled.")
        plug_cycle(cfg, print)
    elif a.cmd == "notify-test":
        notify(cfg, "NetRefresh test", "If you can read this, phone alerts work.")
        send_heartbeat(cfg)
        print("Sent (if a topic / heartbeat URL is set and the server can reach them).")


if __name__ == "__main__":
    main()
