#!/usr/bin/env bash
# MEMBER 4 - Run the dashboard in the foreground (good for demos). Ctrl+C to stop.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/dashboard" && pwd)"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
export DASH_PORT DEV_GROUP
echo "Dashboard: http://localhost:$DASH_PORT   (run with sudo to see LVM/firewall/log data)"
exec python3 "$DIR/server.py"
