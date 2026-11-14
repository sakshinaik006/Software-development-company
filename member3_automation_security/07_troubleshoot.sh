#!/usr/bin/env bash
# MEMBER 3 - Troubleshooting helper. Usage: sudo bash 07_troubleshoot.sh [--fix]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
FIX=0; [[ "$1" == "--fix" ]] && FIX=1

echo "== 1. Disk space ==";   df -hT -x tmpfs -x devtmpfs | awk 'NR==1 || $6+0>=80 {print}'
echo "== 2. Inodes ==";       df -i / "$REPOS_MNT" "$PROJECTS_MNT" 2>/dev/null
echo "== 3. Mounts from fstab ==";
for m in $REPOS_MNT $PROJECTS_MNT $BACKUP_MNT; do
  if mountpoint -q "$m"; then ok "$m mounted"; else warn "$m NOT mounted"; [[ $FIX -eq 1 ]] && { /usr/local/sbin/lab-loop-attach.sh 2>/dev/null; mount "$m" && ok "remounted $m"; }; fi
done
echo "== 4. Services =="
for s in "$(svc_ssh)" "$(svc_cron)"; do
  if systemctl is-active --quiet "$s"; then ok "$s running"; else warn "$s DOWN"; [[ $FIX -eq 1 ]] && systemctl restart "$s" && ok "restarted $s"; fi
done
echo "== 5. Failed systemd units =="; systemctl --failed --no-legend | head
echo "== 6. Load / top CPU processes =="; uptime; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -6
echo "== 7. Top memory processes ==";      ps -eo pid,user,%cpu,%mem,comm --sort=-%mem | head -6
echo "== 8. Biggest directories in /srv =="; du -xh /srv --max-depth=2 2>/dev/null | sort -rh | head -8
echo "== 9. Recent SSH failures =="; (grep -h 'Failed password' /var/log/auth.log /var/log/secure 2>/dev/null | tail -5)
echo "== 10. Recent monitor ALERTs =="; grep ALERT "$LOG_DIR/monitor.log" 2>/dev/null | tail -5
echo "== 11. Last 10 kernel errors =="; dmesg --level=err,crit 2>/dev/null | tail -10
