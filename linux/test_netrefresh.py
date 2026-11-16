"""Tests for netrefresh.py. They use fake time and fake system calls, so they run anywhere:  python3 -m unittest -v"""
import datetime as dt
import os
import struct
import tempfile
import unittest
from unittest import mock

import netrefresh as nr

T0 = dt.datetime(2026, 11, 16, 5, 30, 0)


def cfg(**kw):
    c = dict(nr.DEFAULTS)
    c.update(daily_time="", **kw)
    return c


class FakeWatchdog(nr.Watchdog):
    """Time and the system are fake; everything the watchdog would DO is recorded in .actions."""

    def __init__(self, c, store):
        self.t, self.h, self.actions, self.alerts = T0, "ok", [], []
        super().__init__(c, store)

    def now(self): return self.t
    def health(self): return self.h
    def diagnose(self, kind): return "cause of " + kind
    def log(self, msg): pass
    def alert(self, title, msg): self.alerts.append(title)
    def soft(self): self.actions.append("soft")
    def hard(self): self.actions.append("hard")
    def service(self, unit): self.actions.append("service:" + unit)
    def reboot(self, why): self.actions.append("reboot")

    def advance(self, seconds, step=10):
        for _ in range(seconds // step):
            self.t += dt.timedelta(seconds=step)
            self.tick()


class Parsing(unittest.TestCase):
    def test_default_route(self):
        self.assertEqual(nr.parse_default_route("default via 192.168.1.1 dev eth0 proto dhcp metric 100\n"), ("192.168.1.1", "eth0"))
        self.assertEqual(nr.parse_default_route("default dev wg0 scope link\n"), (None, "wg0"))
        self.assertEqual(nr.parse_default_route(""), (None, None))

    def test_dns_packet_and_reply(self):
        pkt = nr.dns_query_packet("example.com", 0x1234)
        self.assertEqual(pkt[:2], b"\x12\x34")
        self.assertIn(b"\x07example\x03com\x00", pkt)
        self.assertEqual(pkt[-4:], b"\x00\x01\x00\x01")                       # type A, class IN
        ok = struct.pack(">HHHHHH", 0x1234, 0x8180, 1, 1, 0, 0) + b"x" * 20      # response, no error, 1 answer
        self.assertTrue(nr.dns_reply_ok(ok, 0x1234))
        self.assertFalse(nr.dns_reply_ok(ok, 0x9999))                           # wrong id
        self.assertFalse(nr.dns_reply_ok(struct.pack(">HHHHHH", 0x1234, 0x8183, 1, 0, 0, 0), 0x1234))   # NXDOMAIN
        self.assertFalse(nr.dns_reply_ok(struct.pack(">HHHHHH", 0x1234, 0x8180, 1, 0, 0, 0), 0x1234))   # no answers
        self.assertFalse(nr.dns_reply_ok(b"short", 0x1234))


class Ping(unittest.TestCase):
    """A missing or broken `ping` program must not look like an outage."""

    def test_reply_and_no_reply(self):
        with mock.patch.object(nr.shutil, "which", return_value="/bin/ping"):
            with mock.patch.object(nr, "run", return_value=(0, "")):
                self.assertTrue(nr.ping("1.1.1.1"))
            with mock.patch.object(nr, "run", return_value=(1, "")), mock.patch.object(nr.socket, "create_connection", side_effect=AssertionError("no TCP fallback after a clean 'no reply'")):
                self.assertFalse(nr.ping("1.1.1.1"))

    def test_missing_ping_falls_back_to_tcp(self):
        with mock.patch.object(nr.shutil, "which", return_value=None):
            with mock.patch.object(nr.socket, "create_connection", return_value=mock.Mock()) as cc:
                self.assertTrue(nr.ping("1.1.1.1"))
                cc.assert_called_once()
            with mock.patch.object(nr.socket, "create_connection", side_effect=OSError):
                self.assertFalse(nr.ping("192.0.2.1"))

    def test_ping_that_errors_falls_back_too(self):
        with mock.patch.object(nr.shutil, "which", return_value="/bin/ping"), mock.patch.object(nr, "run", return_value=(2, "ping: socket: Operation not permitted")):
            with mock.patch.object(nr.socket, "create_connection", return_value=mock.Mock()):
                self.assertTrue(nr.ping("1.1.1.1"))


class Diagnose(unittest.TestCase):
    ROUTE = ("10.0.0.1", "nrtest0")

    def test_a_gateway_that_drops_ping_is_not_blamed_for_dns_or_service_problems(self):
        with mock.patch.object(nr, "default_route", return_value=self.ROUTE), mock.patch.object(nr, "ping", return_value=False):
            self.assertEqual(nr.diagnose("dns"), "Internet OK but DNS failing (router DNS)")
            self.assertIn("service tailscaled is not running", nr.diagnose("service:tailscaled"))

    def test_internet_outage_router_checks(self):
        with mock.patch.object(nr, "default_route", return_value=self.ROUTE), mock.patch.object(nr, "ping", return_value=False):
            with mock.patch.object(nr, "neighbor_ok", return_value=True):      # answers ARP but not ping
                self.assertTrue(nr.diagnose("internet").startswith("Router OK but no internet"))
            with mock.patch.object(nr, "neighbor_ok", return_value=False):
                self.assertEqual(nr.diagnose("internet"), "Router unreachable (LAN side)")
        with mock.patch.object(nr, "default_route", return_value=(None, None)):
            self.assertEqual(nr.diagnose("internet"), "No default gateway (DHCP lease lost)")

    def test_neighbor_states(self):
        for text, expect in (("10.0.0.1 dev eth0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\n", True), ("10.0.0.1 dev eth0 lladdr aa:bb:cc:dd:ee:ff router STALE\n", True),
                             ("10.0.0.1 dev eth0 FAILED\n", False), ("10.0.0.1 dev eth0 INCOMPLETE\n", False), ("", False)):
            with mock.patch.object(nr, "run", return_value=(0, text)):
                self.assertEqual(nr.neighbor_ok("10.0.0.1"), expect, text)


class Interface(unittest.TestCase):
    def test_keeps_the_last_good_interface_when_the_route_vanishes(self):
        nr._last_dev = None
        with mock.patch.object(nr, "default_route", return_value=("10.0.0.1", "eth0")):
            self.assertEqual(nr.current_dev(), "eth0")
        with mock.patch.object(nr, "default_route", return_value=(None, None)):
            self.assertEqual(nr.current_dev(), "eth0")          # link down: the route is gone, the NIC is still the one to bounce


class Resilience(unittest.TestCase):
    def test_loop_survives_an_exception(self):
        with tempfile.TemporaryDirectory() as d:
            class Boom(FakeWatchdog):
                calls = 0
                def tick(self):
                    Boom.calls += 1
                    if Boom.calls == 1:
                        raise RuntimeError("one bad check")
                    self.stop = True
            w = Boom(dict(cfg(), check_interval=1), nr.Store(d))
            w.run_forever()
            self.assertEqual(Boom.calls, 2)


class StoreAndGraph(unittest.TestCase):
    def test_csv_round_trip_and_open_row(self):
        with tempfile.TemporaryDirectory() as d:
            s = nr.Store(d)
            s.save([{"start": T0, "end": T0 + dt.timedelta(minutes=5), "cause": 'has, comma and "quotes"', "fix": "soft reset"},
                    {"start": T0 + dt.timedelta(hours=1), "end": None, "cause": "open", "fix": ""}])
            rows = s.load()
            self.assertEqual(rows[0]["cause"], 'has, comma and "quotes"')
            self.assertIsNone(rows[1]["end"])
            w = FakeWatchdog(cfg(), s)   # starting the daemon closes the row that a previous run left open
            self.assertEqual(w.rows[1]["fix"], "daemon restarted")
            self.assertIsNotNone(s.load()[1]["end"])

    def test_graph_marks_the_right_columns(self):
        rows = [{"start": T0, "end": T0 + dt.timedelta(minutes=29), "cause": "no internet", "fix": ""},                      # 05:30-05:59 -> column 11
                {"start": T0 - dt.timedelta(days=1, hours=-8), "end": T0 - dt.timedelta(days=1, hours=-9), "cause": "service x is not running", "fix": ""}]   # yesterday 13:30-14:30
        lines = nr.render_graph(rows, T0 + dt.timedelta(hours=2)).splitlines()
        today = lines[1][10:]
        self.assertEqual(len(today), 48)
        self.assertEqual(today[11], "#")
        self.assertEqual(today.count("#"), 1)
        yesterday = lines[2][10:]
        self.assertEqual(yesterday.count("~"), 2)
        self.assertEqual(yesterday[27], "~")                                                                                # 13:30

    def test_summary(self):
        rows = [{"start": T0, "end": T0 + dt.timedelta(minutes=10), "cause": "c", "fix": ""}] * 3
        self.assertIn("3 drops, 30 min down, most often around 05:00", nr.summary(rows, T0 + dt.timedelta(hours=1)))


class Ladder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = nr.Store(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_short_blip_is_not_an_outage(self):
        w = FakeWatchdog(cfg(), self.store)
        w.h = "internet"; w.advance(20)       # 2 failed checks only
        w.h = "ok"; w.advance(10)
        self.assertEqual(w.rows, [])
        self.assertEqual(w.actions, [])

    def test_escalates_soft_hard_reboot_once_each(self):
        w = FakeWatchdog(cfg(), self.store)
        w.h = "internet"
        w.advance(60); self.assertEqual(w.actions, [])
        w.advance(60); self.assertEqual(w.actions, ["soft"])                  # about 90 s in
        w.advance(240); self.assertEqual(w.actions, ["soft", "hard"])         # about 5 min
        w.advance(700); self.assertEqual(w.actions, ["soft", "hard", "reboot"])   # about 15 min
        w.advance(600); self.assertEqual(w.actions.count("reboot"), 1)        # never again within the same outage
        self.assertEqual(w.rows[0]["fix"], "reboot")
        self.assertIn("NetRefresh: DOWN", w.alerts)

    def test_recovery_closes_the_row_with_the_last_fix(self):
        w = FakeWatchdog(cfg(), self.store)
        w.h = "dns"; w.advance(130)
        w.h = "ok"; w.advance(10)
        r = w.store.load()[0]
        self.assertEqual((r["fix"], r["cause"]), ("soft reset", "cause of dns"))
        self.assertIsNotNone(r["end"])
        self.assertIn("NetRefresh: back UP", w.alerts)
        self.assertEqual(r["start"], T0 + dt.timedelta(seconds=10))           # dated from the FIRST failed check

    def test_unaided_recovery_says_self_recovered(self):
        w = FakeWatchdog(cfg(), self.store)
        w.h = "internet"; w.advance(50)
        w.h = "ok"; w.advance(10)
        self.assertEqual(w.store.load()[0]["fix"], "self-recovered")
        self.assertEqual(w.actions, [])

    def test_a_dead_service_is_restarted_but_never_causes_a_reboot(self):
        w = FakeWatchdog(cfg(), self.store)
        w.h = "service:tailscaled"; w.advance(1500)
        self.assertEqual(w.actions, ["service:tailscaled", "service:tailscaled"])
        self.assertEqual(w.rows[0]["fix"], "restart tailscaled")

    def test_reboot_cooldown_and_switch(self):
        self.store.set_last_reboot(T0 - dt.timedelta(hours=1))
        w = FakeWatchdog(cfg(), self.store)
        w.h = "internet"; w.advance(1000)
        self.assertNotIn("reboot", w.actions)                                  # rebooted 1 h ago: cooldown holds
        w2 = FakeWatchdog(cfg(reboot_last_resort=False), nr.Store(tempfile.mkdtemp()))
        w2.h = "internet"; w2.advance(1000)
        self.assertNotIn("reboot", w2.actions)                                 # switched off

    def test_daily_reset_and_daily_reboot_guard(self):
        w = FakeWatchdog(dict(cfg(), daily_time="06:15"), self.store)
        self.assertEqual(w.next_daily, dt.datetime(2026, 11, 16, 6, 15))
        w.t = dt.datetime(2026, 11, 16, 6, 15, 1); w.check_daily()
        self.assertEqual(w.actions, ["soft"])
        self.assertEqual(w.next_daily, dt.datetime(2026, 11, 17, 6, 15))       # tomorrow
        w3 = FakeWatchdog(dict(cfg(), daily_time="06:15", daily_action="reboot"), nr.Store(tempfile.mkdtemp()))
        w3.t = dt.datetime(2026, 11, 16, 6, 15, 1); w3.check_daily()
        self.assertEqual(w3.actions, ["reboot"])
        w3.t = dt.datetime(2026, 11, 17, 6, 15, 1)
        w3.store.set_last_reboot(w3.t - dt.timedelta(minutes=3))                # just rebooted: do a soft reset instead of looping
        w3.next_daily = w3.t; w3.check_daily()
        self.assertEqual(w3.actions, ["reboot", "soft"])


class Config(unittest.TestCase):
    def test_bad_values_are_rejected(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"daily_time": "25:99"}')
        try:
            with self.assertRaises(SystemExit):
                nr.load_config(f.name)
        finally:
            os.unlink(f.name)

    def test_missing_file_gives_defaults(self):
        self.assertEqual(nr.load_config("/nonexistent/config.json")["daily_action"], "reset")


if __name__ == "__main__":
    unittest.main()
