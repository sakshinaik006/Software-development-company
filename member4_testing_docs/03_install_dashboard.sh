#!/usr/bin/env bash
# MEMBER 4 - Installs the web dashboard as a systemd service (auto-start at boot).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
DIR="$INSTALL_DIR/member4_testing_docs/dashboard"
[[ -d "$DIR" ]] || { mkdir -p "$INSTALL_DIR"; rsync -a "$PROJECT_ROOT"/ "$INSTALL_DIR"/; }
cat > /etc/systemd/system/devserver-dashboard.service <<EOT
[Unit]
Description=Dev Server Monitoring Dashboard
After=network.target

[Service]
Environment=DASH_PORT=$DASH_PORT
Environment=DEV_GROUP=$DEV_GROUP
# Uncomment to require a login:
#Environment=DASH_USER=admin
#Environment=DASH_PASS=ChangeMe123
ExecStart=/usr/bin/python3 $DIR/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload; systemctl enable --now devserver-dashboard
sleep 1; systemctl is-active devserver-dashboard && ok "Dashboard running -> http://$(hostname -I | awk '{print $1}'):$DASH_PORT"
