#!/usr/bin/env bash
# MEMBER 4 - Builds a Markdown system report (evidence/screenshots source for documentation).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
R="$LOG_DIR/system_report.md"
sec() { { echo; echo "## $1"; echo '```'; eval "$2" 2>&1; echo '```'; } >> "$R"; }
echo "# Linux Development Server - System Report" > "$R"
echo "Generated: $(date)   Host: $(hostname)" >> "$R"

sec "1. System information"            "uname -a; cat /etc/os-release | head -3; uptime"
sec "2. Users and groups"              "getent group $DEV_GROUP; echo; getent passwd | grep '^${DEV_PREFIX}' | head -5; echo ...; echo Total developers: \$(getent passwd | grep -c '^${DEV_PREFIX}')"
sec "3. Block devices & partitions"    "lsblk"
sec "4. LVM layout"                    "pvs; vgs; lvs"
sec "5. File systems & mounts"         "df -hT -x tmpfs -x devtmpfs; echo; grep -E 'srv|backup' /etc/fstab"
sec "6. Shared repositories"           "ls -la $REPOS_MNT $PROJECTS_MNT"
sec "7. Backups"                       "ls -lh $BACKUP_DIR"
sec "8. Cron jobs"                     "cat /etc/cron.d/devserver"
sec "9. Firewall"                      "ufw status verbose 2>/dev/null || firewall-cmd --list-all"
sec "10. SSH hardening"                "sshd -T | grep -Ei 'permitroot|maxauth|x11'"
sec "11. Monitoring log (last 10)"     "tail -10 $LOG_DIR/monitor.log"
sec "12. Test results"                 "cat $LOG_DIR/test_report.txt"
ok "report written: $R"
