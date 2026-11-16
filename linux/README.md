# NetRefresh for Linux servers

A headless version of NetRefresh for a Linux box you reach remotely. One Python file (standard library only, Python 3.7+), run as a systemd service.

**This folder is independent of the Windows app. Delete the `linux/` folder if you don't use Linux.**

## What it does

- **Watchdog** (every 10 s): internet by ping, your DNS server asked directly over UDP (so a local cache cannot hide a failure), and any systemd services you list (for example `tailscaled`, `ssh`).
- **Escalation ladder** when something stays down: soft reset after 90 s (flush DNS, bounce the link, renew the lease), hard reset after 5 min (restart NetworkManager or systemd-networkd and systemd-resolved), optional reboot after 15 min (at most once per 3 h). A broken *service* is only restarted, never a reboot.
- **Cause detection**: link down, no gateway, router unreachable, ISP/WAN drop, DNS failure, service stopped.
- **History**: `outages.csv`, `netrefresh.log` and a 7-day text graph.
- **Daily action** at a time you choose: a soft network reset, or a full reboot.
- **Phone alerts** through [ntfy.sh](https://ntfy.sh): outage start, recovery with cause and fix, reboots.

Not here (they make no sense on a server): auto-login, tray icon, "open an app at login".

## Install

```sh
git clone https://github.com/jurkos4/NetRefresh
cd NetRefresh/linux
sudo ./install.sh
```

This copies the script to `/opt/netrefresh`, creates `/etc/netrefresh/config.json` and `/var/lib/netrefresh`, and starts a `netrefresh` systemd service. Needs systemd and `python3`. Edit the config, then `sudo systemctl restart netrefresh`.

Remove it with `sudo ./install.sh uninstall` (your config and history are kept). If the machine must never suspend: `sudo ./install.sh mask-sleep`.

## Config (`/etc/netrefresh/config.json`)

| key | default | meaning |
|---|---|---|
| `daily_time` | `"06:15"` | `HH:MM` every day, or `""` for none |
| `daily_action` | `"reset"` | `"reset"` (soft network reset) or `"reboot"` |
| `check_interval` | `10` | seconds between checks |
| `ping_hosts` | `["1.1.1.1","8.8.8.8"]` | internet is "down" only if all fail |
| `dns_name` | `"example.com"` | looked up on the upstream DNS server |
| `watch_services` | `[]` | systemd units that must stay active, restarted if not |
| `reboot_last_resort` | `true` | reboot if still down after 15 min |
| `ntfy_topic` | `""` | phone alerts; use a long random topic, it is the only secret (the config is mode 640) |
| `data_dir` | `"/var/lib/netrefresh"` | where history and log live |

## Commands

```sh
netrefresh status           # check now + recent outages
netrefresh graph            # 7-day graph
sudo netrefresh reset soft  # run a repair now (or: hard)
sudo netrefresh reboot      # asks first, reboots in 1 minute (cancel: shutdown -c)
netrefresh notify-test      # test the phone alert
journalctl -u netrefresh -f # live log
```

```
Last 7 days: 4 drops, 195 min down, most often around 05:00

          00    03    06    09    12    15    18    21
Mon 16.11 ...........#....................................
Sun 15.11 ..........###...................................
Sat 14.11 ...........................~~~~.................
# internet down   ~ remote service down   . ok   (one row per day, 30 minutes per character)
```

## Good to know

- **Tested:** the logic has unit tests that run anywhere: `python3 -m unittest -v`. It has also been run end to end on Ubuntu 24.04 (WSL2 with systemd): install and service, outage detection and diagnosis, the soft reset at 90 s and hard reset at 5 min, recovery and history, a watched service restarted without touching the network, the daily action, and a system without the `ping` program.
- **Not tested yet:** a real reboot, NetworkManager / systemd-networkd restarts and DHCP renewal on real hardware (WSL has neither), and other distros. Please open an issue if something misbehaves on yours.
- Distros without systemd are not supported by the installer. Without NetworkManager or systemd-networkd only the link bounce is done.
- Automatic reboots from `unattended-upgrades` are a separate setting (`Unattended-Upgrade::Automatic-Reboot`); NetRefresh does not change it.
- Cannot help if the server is powered off or the ISP is really down.
