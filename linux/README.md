# NetRefresh for Linux servers

A headless version of NetRefresh for a Linux box you reach remotely. One Python file (standard library only, Python 3.7+), run as a systemd service.

**This folder is independent of the Windows app. Delete the `linux/` folder if you don't use Linux.**

## What it does

- **Watchdog** (every 10 s): internet by ping and, for networks that block ping, a TCP connection to port 443; your DNS server asked directly over UDP (so a local cache cannot hide a failure); and any systemd services you list (for example `tailscaled`, `ssh`).
- **Repairs chosen by cause.** An outage starts after 3 failed checks in a row (~30 s):

  | Cause found | at 90 s | at 5 min | at 15 min |
  |---|---|---|---|
  | Link down / no gateway | restart the link, renew the lease | restart NetworkManager or systemd-networkd and the resolver | reboot* |
  | Router not answering | restart the link | power-cycle the router (smart plug) | reboot* |
  | Router fine, no internet (ISP) | nothing (waits, logs) | power-cycle the router (smart plug) | nothing |
  | DNS failing | flush DNS | renew the lease | nothing |
  | Watched service stopped | restart it | restart it | nothing |

  \*optional, at most once per 3 h. The cause is checked again at each step.
- **Link restarts are safe**: the default route is remembered while the network works and put back after a link restart (taking a link down deletes its routes, and without NetworkManager or systemd-networkd nothing would add them back). Debian ifupdown interfaces are restarted with `ifdown`/`ifup`.
- **Router power-cycle through a smart plug** (Shelly Gen1, Shelly Gen2+, Tasmota). The plug switches itself back on after 30 s. At most 3 times a day, 30 min apart.
- **History**: `outages.csv`, `netrefresh.log`, a 7-day text graph and an **ISP report**.
- **Alerts**: phone alerts through [ntfy.sh](https://ntfy.sh), and a **heartbeat** to [healthchecks.io](https://healthchecks.io) (or self-hosted) every 5 min, which alerts you when the server stops checking in.
- **Daily action** at a time you choose: a network reset, or a full reboot.

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
| `daily_action` | `"reset"` | `"reset"` (network reset) or `"reboot"` |
| `check_interval` | `10` | seconds between checks |
| `ping_hosts` | `["1.1.1.1","8.8.8.8"]` | internet is "down" only if all fail ping AND port 443 |
| `dns_name` | `"example.com"` | looked up on the upstream DNS server |
| `watch_services` | `[]` | systemd units that must stay active, restarted if not |
| `reboot_last_resort` | `true` | reboot if a local fault lasts 15 min |
| `ntfy_topic` | `""` | phone alerts; use a long random topic, it is the only secret (the config is mode 640) |
| `heartbeat_url` | `""` | ping URL from healthchecks.io or similar |
| `router_plug` | `{"type": "", "host": ""}` | `type`: `shelly1`, `shelly2` or `tasmota`; `host`: the plug's IP |
| `data_dir` | `"/var/lib/netrefresh"` | where history and log live |

## Commands

```sh
netrefresh status           # check now + recent outages
netrefresh graph            # 7-day graph
netrefresh report           # ISP report (last 30 days; --days N)
sudo netrefresh reset soft  # run a repair now (or: hard)
sudo netrefresh reboot      # asks first, reboots in 1 minute (cancel: shutdown -c)
netrefresh plug-test        # power-cycle the router through the plug (asks first)
netrefresh notify-test      # test the phone alert and the heartbeat
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

- **Tested:** unit tests that run anywhere: `python3 -m unittest -v`. Also run end to end on Ubuntu 24.04 (WSL2 with systemd): install and service, a local fault that repaired itself (link restart plus route restore), an ISP outage that left the server alone and power-cycled the router through a stand-in plug, heartbeat, ISP report, a watched service restarted without touching the network, the daily action, and a system without the `ping` program.
- **Not tested yet:** a real reboot, NetworkManager / systemd-networkd restarts and DHCP renewal on real hardware (WSL has neither), real smart plugs, and other distros. Please open an issue if something misbehaves on yours.
- Distros without systemd are not supported by the installer.
- Automatic reboots from `unattended-upgrades` are a separate setting (`Unattended-Upgrade::Automatic-Reboot`); NetRefresh does not change it.
