"""Tests for netrefresh.py. They use fake time and fake system calls, so they run anywhere:  python3 -m unittest -v"""
import datetime as dt
import os
import struct
import tempfile
import unittest
from unittest import mock

import netrefresh as nr

T0 = dt.datetime(2026, 11, 16, 5, 30, 0)
LOCAL = "No default gateway (DHCP lease lost)"
ISP = "Router OK but no internet (ISP/WAN drop or router reconnect)"
ROUTER = "Router unreachable (LAN side)"
PLUG = {"router_plug": {"type": "shelly2", "host": "192.168.1.50"}}


def cfg(**kw):
    c = dict(nr.DEFAULTS)
    c.update(daily_time="", **kw)
    return c


class FakeWatchdog(nr.Watchdog):
    """Time and the system are fake; every repair the watchdog would DO is recorded in .actions."""

    def __init__(self, c, store):
        self.t, self.h, self.cause, self.actions, self.alerts, self.beats = T0, "ok", LOCAL, [], [], 0
        super().__init__(c, store)

    def now(self): return self.t
    def health(self): return self.h
    def diagnose(self, kind): return self.cause
    def log(self, msg): pass
    def alert(self, title, msg): self.alerts.append(title)
    def beat(self): self.beats += 1
    def internet(self): return self.h == "ok"
    def soft(self): self.actions.append("daily soft")
    def reboot(self, why): self.actions.append("reboot")

    def act(self, action, unit=None):
        if action == "reboot":
            self.reboot("x")
        else:
            self.actions.append(action + (":" + unit if unit else ""))
        return True

    def advance(self, seconds, step=10):
        for _ in range(seconds // step):
            self.t += dt.timedelta(seconds=step)
            self.tick()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = nr.Store(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def dog(self, h="ok", cause=LOCAL, **kw):
        w = FakeWatchdog(cfg(**kw), self.store)
        w.h, w.cause = h, cause
        return w


class Parsing(unittest.TestCase):
    def test_default_route(self):
        self.assertEqual(nr.parse_default_route("default via 192.168.1.1 dev eth0 proto dhcp metric 100\n"), ("192.168.1.1", "eth0"))
        self.assertEqual(nr.parse_default_route("default dev wg0 scope link\n"), (None, "wg0"))
        self.assertEqual(nr.parse_default_route(""), (None, None))

    def test_route_args_for_restoring(self):
        self.assertEqual(nr.route_args("default via 172.22.160.1 dev eth0 proto kernel onlink\n"), ["default", "via", "172.22.160.1", "dev", "eth0", "onlink"])
        self.assertIsNone(nr.route_args("default dev wg0 scope link\n"))

    def test_dns_packet_and_reply(self):
        pkt = nr.dns_query_packet("example.com", 0x1234)
        self.assertEqual(pkt[:2], b"\x12\x34")
        self.assertIn(b"\x07example\x03com\x00", pkt)
        ok = struct.pack(">HHHHHH", 0x1234, 0x8180, 1, 1, 0, 0) + b"x" * 20
        self.assertTrue(nr.dns_reply_ok(ok, 0x1234))
        self.assertFalse(nr.dns_reply_ok(ok, 0x9999))
        self.assertFalse(nr.dns_reply_ok(struct.pack(">HHHHHH", 0x1234, 0x8183, 1, 0, 0, 0), 0x1234))
        self.assertFalse(nr.dns_reply_ok(b"short", 0x1234))

    def test_cause_classes(self):
        self.assertEqual(nr.cause_class("Ethernet link down (cable/NIC/driver)"), "local")   # old history rows
        self.assertEqual(nr.cause_class(LOCAL), "local")
        self.assertEqual(nr.cause_class(ROUTER), "router")
        self.assertEqual(nr.cause_class(ISP), "isp")
        self.assertEqual(nr.cause_class("Internet OK but DNS failing (router DNS)"), "dns")
        self.assertEqual(nr.cause_class("Internet OK but service ssh is not running (remote access)"), "remote")

    def test_plug_urls(self):
        self.assertEqual(nr.plug_url({"type": "shelly2", "host": "10.0.0.5"}), "http://10.0.0.5/rpc/Switch.Set?id=0&on=false&toggle_after=30")
        self.assertEqual(nr.plug_url({"type": "tasmota", "host": "10.0.0.5"}), "http://10.0.0.5/cm?cmnd=Backlog%20Power1%20Off%3BDelay%20300%3BPower1%20On")
        self.assertIsNone(nr.plug_url({"type": "shelly2", "host": "10.0.0.5/x?evil"}))
        self.assertIsNone(nr.plug_url({"type": "", "host": "10.0.0.5"}))


class Probes(unittest.TestCase):
    def test_ping_falls_back_to_tcp_when_ping_is_missing_or_broken(self):
        with mock.patch.object(nr.shutil, "which", return_value=None), mock.patch.object(nr, "tcp_ok", return_value=True):
            self.assertTrue(nr.ping("1.1.1.1"))
        with mock.patch.object(nr.shutil, "which", return_value="/bin/ping"), mock.patch.object(nr, "run", return_value=(2, "socket: Operation not permitted")), \
                mock.patch.object(nr, "tcp_ok", return_value=True):
            self.assertTrue(nr.ping("1.1.1.1"))
        with mock.patch.object(nr.shutil, "which", return_value="/bin/ping"), mock.patch.object(nr, "run", return_value=(1, "")), \
                mock.patch.object(nr, "tcp_ok", side_effect=AssertionError("no fallback after a clean no-reply")):
            self.assertFalse(nr.ping("1.1.1.1"))

    def test_internet_is_up_when_ping_is_blocked_but_443_answers(self):
        with mock.patch.object(nr, "ping", return_value=False), mock.patch.object(nr, "tcp_ok", side_effect=lambda h, p, t=1.5: p == 443):
            self.assertTrue(nr.internet_up(cfg()))
        with mock.patch.object(nr, "ping", return_value=False), mock.patch.object(nr, "tcp_ok", return_value=False):
            self.assertFalse(nr.internet_up(cfg()))

    def test_keeps_last_interface_and_route_when_the_route_vanishes(self):
        nr._last_dev = None
        nr._last_route = None
        with mock.patch.object(nr, "default_route_text", return_value="default via 10.0.0.1 dev eth0 proto dhcp\n"):
            self.assertEqual(nr.current_dev(), "eth0")
            nr.remember_route()
        with mock.patch.object(nr, "default_route_text", return_value=""), mock.patch.object(nr, "run") as run:
            self.assertEqual(nr.current_dev(), "eth0")
            nr.restore_route(lambda m: None)
            run.assert_called_with(["ip", "route", "replace", "default", "via", "10.0.0.1", "dev", "eth0"])

    def test_gateway_that_drops_ping_is_not_blamed_for_dns_or_services(self):
        with mock.patch.object(nr, "default_route", return_value=("10.0.0.1", "nrtest0")), mock.patch.object(nr, "ping", return_value=False):
            self.assertEqual(nr.diagnose("dns"), "Internet OK but DNS failing (router DNS)")
            with mock.patch.object(nr, "neighbor_ok", return_value=True):
                self.assertEqual(nr.diagnose("internet"), ISP)
            with mock.patch.object(nr, "neighbor_ok", return_value=False):
                self.assertEqual(nr.diagnose("internet"), ROUTER)


class Ladder(Base):
    def test_a_short_blip_is_not_an_outage(self):
        w = self.dog("internet")
        w.advance(20)
        w.h = "ok"
        w.advance(10)
        self.assertEqual((w.rows, w.actions), ([], []))

    def test_local_fault_adapter_then_device_then_one_reboot(self):
        w = self.dog("internet", LOCAL)
        w.advance(1600)
        self.assertEqual(w.actions, ["adapter restart", "device restart", "reboot"])
        self.assertEqual(w.rows[0]["fix"], "reboot")
        self.assertIn("NetRefresh: DOWN", w.alerts)

    def test_isp_outage_never_resets_the_server(self):
        w = self.dog("internet", ISP)
        w.advance(1600)
        self.assertEqual(w.actions, [])

    def test_isp_outage_with_a_plug_power_cycles_the_router_once(self):
        w = self.dog("internet", ISP, **PLUG)
        w.advance(1600)
        self.assertEqual(w.actions, ["router power-cycle"])

    def test_plug_limits(self):
        w = self.dog("internet", ISP, **PLUG)
        w.advance(400)
        w.h = "ok"
        w.advance(30)
        w.h = "internet"
        w.advance(400)
        self.assertEqual(w.actions, ["router power-cycle"])          # 30 min gap
        st = self.store.state()
        st["plug_times"] = [T0 - dt.timedelta(hours=h) for h in (5, 3, 1)]
        self.store.save_state(st)
        w2 = self.dog("internet", ISP, **PLUG)
        w2.advance(400)
        self.assertEqual(w2.actions, [])                             # 3 per day

    def test_router_unreachable(self):
        self.assertEqual(self._run(ROUTER), ["adapter restart", "device restart", "reboot"])
        self.store.save_state({"last_reboot": dt.datetime.min, "plug_times": []})
        self.assertEqual(self._run(ROUTER, **PLUG), ["adapter restart", "router power-cycle", "reboot"])

    def _run(self, cause, **kw):
        w = self.dog("internet", cause, **kw)
        w.advance(1000)
        return w.actions

    def test_dns_and_service_never_reboot(self):
        w = self.dog("dns", "Internet OK but DNS failing (router DNS)")
        w.advance(1600)
        self.assertEqual(w.actions, ["flush DNS", "renew lease"])
        w2 = self.dog("service:tailscaled", "Internet OK but service tailscaled is not running (remote access)")
        w2.advance(1600)
        self.assertEqual(w2.actions, ["restart service:tailscaled", "restart service:tailscaled"])
        self.assertEqual(w2.rows[-1]["fix"], "restart tailscaled")

    def test_cause_is_rechecked_each_stage(self):
        w = self.dog("internet", LOCAL)
        w.advance(100)
        w.cause = ISP
        w.advance(1500)
        self.assertEqual(w.actions, ["adapter restart"])

    def test_reboot_cooldown_and_switch(self):
        self.store.set_last_reboot(T0 - dt.timedelta(hours=1))
        self.assertNotIn("reboot", self._run(LOCAL))
        self.store.set_last_reboot(dt.datetime.min)
        self.assertNotIn("reboot", self._run(LOCAL, reboot_last_resort=False))

    def test_recovery_records_the_last_repair(self):
        w = self.dog("internet", LOCAL)
        w.advance(130)
        w.h = "ok"
        w.advance(10)
        r = self.store.load()[0]
        self.assertEqual((r["fix"], r["start"]), ("adapter restart", T0 + dt.timedelta(seconds=10)))
        self.assertIn("NetRefresh: back UP", w.alerts)

    def test_heartbeat_every_five_minutes(self):
        w = self.dog("ok")
        w.advance(610)
        self.assertEqual(w.beats, 3)

    def test_daily_reset_and_daily_reboot_guard(self):
        w = FakeWatchdog(dict(cfg(), daily_time="06:15"), self.store)
        w.t = dt.datetime(2026, 11, 16, 6, 15, 1)
        w.check_daily()
        self.assertEqual(w.actions, ["daily soft"])
        self.assertEqual(w.next_daily, dt.datetime(2026, 11, 17, 6, 15))
        w3 = FakeWatchdog(dict(cfg(), daily_time="06:15", daily_action="reboot"), nr.Store(tempfile.mkdtemp()))
        w3.t = dt.datetime(2026, 11, 16, 6, 15, 1)
        w3.check_daily()
        self.assertEqual(w3.actions, ["reboot"])
        w3.t = dt.datetime(2026, 11, 17, 6, 15, 1)
        w3.store.set_last_reboot(w3.t - dt.timedelta(minutes=3))
        w3.next_daily = w3.t
        w3.check_daily()
        self.assertEqual(w3.actions, ["reboot", "daily soft"])

    def test_loop_survives_an_exception(self):
        class Boom(FakeWatchdog):
            calls = 0

            def tick(self):
                Boom.calls += 1
                if Boom.calls == 1:
                    raise RuntimeError("one bad check")
                self.stop = True
        Boom(dict(cfg(), check_interval=1), self.store).run_forever()
        self.assertEqual(Boom.calls, 2)


class Files(Base):
    def test_csv_round_trip_damaged_and_open_rows(self):
        self.store.save([{"start": T0, "end": T0 + dt.timedelta(minutes=5), "cause": 'has, comma and "quotes"', "fix": "adapter restart"},
                         {"start": T0 + dt.timedelta(hours=1), "end": None, "cause": "open", "fix": ""}])
        with open(self.store.csv, "a") as f:
            f.write('"garbage","","x",""\n')
        rows = self.store.load()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["cause"], 'has, comma and "quotes"')
        w = FakeWatchdog(cfg(), self.store)
        self.assertEqual(w.rows[1]["fix"], "watchdog restarted")

    def test_graph_report_pattern(self):
        days = [{"start": T0 - dt.timedelta(days=d), "end": T0 - dt.timedelta(days=d) + dt.timedelta(minutes=20), "cause": ISP, "fix": ""} for d in (1, 2, 3)]
        other = {"start": T0 - dt.timedelta(days=4), "end": T0 - dt.timedelta(days=4) + dt.timedelta(minutes=50), "cause": LOCAL, "fix": ""}
        self.assertEqual(nr.daily_pattern(days, T0), (5, 3))
        self.assertIsNone(nr.daily_pattern(days[:2], T0))
        rep = nr.isp_report(days + [other], T0)
        self.assertIn("(an ISP-side problem): 3, 60 minutes", rep)
        self.assertIn("All outages in the period: 4", rep)
        graph = nr.render_graph(days, T0).splitlines()
        self.assertEqual(graph[2][10:][11], "#")          # yesterday 05:30

    def test_bad_config_is_rejected(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"router_plug": {"type": "shelly2", "host": "x/y?z"}}')
        try:
            with self.assertRaises(SystemExit):
                nr.load_config(f.name)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
