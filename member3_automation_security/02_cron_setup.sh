#!/usr/bin/env bash
# MEMBER 3 - Deploys project to /opt/devserver and installs cron jobs + logrotate.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

mkdir -p "$INSTALL_DIR"
rsync -a --delete "$PROJECT_ROOT"/ "$INSTALL_DIR"/ && ok "project deployed to $INSTALL_DIR"
find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

cat > /etc/cron.d/devserver <<EOT
# Managed by Member 3 - Automation & Security Engineer
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# min hour dom mon dow user command
# Every job: flock = exit if previous run still active, timeout = kill if it hangs.
*/5 *  * * *   root  flock -n /var/lock/dev-monitor.lock timeout 120 /bin/bash $INSTALL_DIR/member3_automation_security/06_monitor.sh >> $LOG_DIR/cron.log 2>&1
# Backup at 02:00 and a safety retry at 02:30 - the script itself skips if today's valid backup exists.
0   2  * * *   root  timeout 2h /bin/bash $INSTALL_DIR/member2_storage_backup/05_backup.sh >> $LOG_DIR/cron.log 2>&1
30  2  * * *   root  timeout 2h /bin/bash $INSTALL_DIR/member2_storage_backup/05_backup.sh >> $LOG_DIR/cron.log 2>&1
30  3  * * 0   root  flock -n /var/lock/dev-cleanup.lock timeout 1h /bin/bash $INSTALL_DIR/member3_automation_security/01_cleanup.sh >> $LOG_DIR/cron.log 2>&1
0   6  * * *   root  flock -n /var/lock/dev-tests.lock timeout 30m /bin/bash $INSTALL_DIR/member4_testing_docs/01_run_tests.sh --quiet >> $LOG_DIR/cron.log 2>&1
EOT
chmod 644 /etc/cron.d/devserver

cat > /etc/logrotate.d/devserver <<EOT
$LOG_DIR/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOT
systemctl restart "$(svc_cron)" 2>/dev/null
ok "cron jobs installed:"; cat /etc/cron.d/devserver
log "Cron scheduling configured"
