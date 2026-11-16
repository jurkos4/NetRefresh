# NetRefresh

A small Windows tool for a PC you need to reach remotely while you are away. It watches your connection, repairs it in escalating steps, records every outage with its cause, and brings the PC back after a restart.

It is one window (WinForms, hosted in a tiny C# exe) and the logic is a single readable PowerShell script, `NetRefresh.ps1`.

## What it does

- **Daily scheduled reset** at a time you choose: flush DNS, restart the adapters, renew the lease, restart your remote-access tool. Or restart the whole PC instead.
- **Watchdog** (every 10 s): internet by ping, your router's DNS asked directly, and optionally the Chrome Remote Desktop service or Tailscale.
- **Escalation ladder** when something stays down: soft reset after 90 s, hard reset after 5 min (Winsock and IP stack reset, device restart), optional PC reboot after 15 min (at most once per 3 h).
- **Cause detection**: Ethernet link, no gateway, router unreachable, ISP/WAN drop, DNS failure, remote tool stopped.
- **Outage history**: `outages.csv`, `netrefresh.log`, and a 7-day graph (one row per day) with the list of outages.
- **Come back after a restart**: optional auto-login, start with Windows (admin, no prompt) and open a chosen app (pick it from a searchable list of your Start-menu apps).
- **Extras**: keep the PC awake, stop Windows Update restarting it by itself, tray icon with pop-ups, phone alerts through [ntfy.sh](https://ntfy.sh), a test-restart button.

## Build and run

Needs Windows 10/11 and nothing else: the C# compiler that ships with Windows is used.

1. Run `build.bat`. It embeds `NetRefresh.ps1` into `NetRefresh.exe`.
2. Run `NetRefresh.exe` and accept the admin prompt (needed to restart adapters).
3. Pick a time, press **Start**, leave it running. Tick **Start with Windows** to survive restarts.

The exe is built locally and unsigned, so Windows SmartScreen or antivirus may warn about a downloaded copy. That is why this repo ships source and a build script instead of a binary.

For a quick look without admin rights: `powershell -File NetRefresh.ps1 -Preview` (resets will fail, everything else works).

## Auto-login: read this

The **Auto-login** tab makes Windows sign in by itself after a restart, so the PC comes back to your desktop. This is optional.

- The password is checked once against Windows, then stored the way Sysinternals Autologon stores it: as an encrypted LSA secret. NetRefresh never writes it to its own files or the log, and the box is cleared afterwards.
- It also turns off "Windows Hello only" sign-in, which Windows needs for auto-login.
- Anyone with physical access to the PC can then sign in without a password, and an administrator on the PC can read the stored password with tools. Use **Disable** when you no longer need it.
- Use your account password. For a Microsoft account that is the Microsoft account password, not the PIN.

## Notes and limits

- Windows only. Resets need admin, so the exe asks for it.
- Cannot help if the PC is powered off or the ISP is really down.
- The phone-alert topic is the only secret in ntfy.sh: use a long random one.
- If a remote tool is logged out (for example Tailscale), only a person can sign it in again; NetRefresh reports it but does not restart in a loop.

## License

MIT, see `LICENSE`.
