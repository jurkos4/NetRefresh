#!/bin/sh
# Installs NetRefresh as a systemd service.   sudo ./install.sh [install|uninstall|mask-sleep]
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./install.sh"; exit 1; }
cd "$(dirname "$0")"

DEST=/opt/netrefresh
CONF=/etc/netrefresh/config.json
UNIT=/etc/systemd/system/netrefresh.service

case "${1:-install}" in
  install) ;;
  uninstall)
    systemctl disable --now netrefresh 2>/dev/null || true
    rm -f "$UNIT" /usr/local/bin/netrefresh
    rm -rf "$DEST"
    systemctl daemon-reload
    echo "Removed. Your config (/etc/netrefresh) and history (/var/lib/netrefresh) were kept."
    exit 0 ;;
  mask-sleep)
    # for a box that must never suspend; undo with: systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    exit 0 ;;
  *) echo "usage: sudo ./install.sh [install|uninstall|mask-sleep]"; exit 1 ;;
esac

command -v systemctl >/dev/null || { echo "systemd is required."; exit 1; }
PY=$(command -v python3) || { echo "python3 is required."; exit 1; }
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 7))' || { echo "Python 3.7 or newer is required."; exit 1; }

command -v ping >/dev/null || echo "Note: 'ping' is not installed, NetRefresh will check with TCP connections instead."
command -v ip >/dev/null || echo "Note: 'ip' (iproute2) is not installed, so the link cannot be bounced and causes will be less precise."

install -d "$DEST" /etc/netrefresh
install -d -m 755 /var/lib/netrefresh
install -m 755 netrefresh.py "$DEST/netrefresh.py"
# 640: the ntfy topic in the config acts as a password
[ -f "$CONF" ] || install -m 640 config.example.json "$CONF"
ln -sf "$DEST/netrefresh.py" /usr/local/bin/netrefresh

cat > "$UNIT" <<EOF
[Unit]
Description=NetRefresh network watchdog
After=network.target

[Service]
Environment=PYTHONUNBUFFERED=1
ExecStart=$PY $DEST/netrefresh.py run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now netrefresh
echo "Installed and running. Edit $CONF, then: sudo systemctl restart netrefresh"
echo "Try:  netrefresh status   |   netrefresh graph   |   journalctl -u netrefresh -f"
