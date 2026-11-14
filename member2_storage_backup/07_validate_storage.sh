#!/usr/bin/env bash
# MEMBER 2 - Storage validation: LVM objects, mounts, fstab, write test, free space.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else echo -e "\e[31m[FAIL]\e[0m $1"; fail=1; fi; }

chk "Volume group $VG_NAME exists"  "vgs $VG_NAME"
EXTRA_LV=""; EXTRA_M=""; [[ "$DOCKER_ENABLE" == "yes" ]] && { EXTRA_LV="$LV_DOCKER"; EXTRA_M="$DOCKER_MNT"; }
for lv in $LV_REPOS $LV_PROJECTS $LV_BACKUP $EXTRA_LV; do chk "LV $lv exists" "lvs $VG_NAME/$lv"; done
for m in $REPOS_MNT $PROJECTS_MNT $BACKUP_MNT $EXTRA_M; do
  chk "$m is mounted"        "mountpoint -q $m"
  chk "$m in /etc/fstab"     "grep -q ' $m ' /etc/fstab"
  chk "$m writable"          "touch $m/.wtest && rm -f $m/.wtest"
  use=$(df --output=pcent "$m" | tail -1 | tr -dc 0-9)
  chk "$m usage ${use}% < ${DISK_ALERT}%" "[ ${use:-100} -lt $DISK_ALERT ]"
done
chk "At least one backup exists" "ls $BACKUP_DIR/backup_*.tar.gz"
echo; vgs; lvs
df_list=("$REPOS_MNT" "$PROJECTS_MNT" "$BACKUP_MNT")
[[ "$DOCKER_ENABLE" == "yes" ]] && df_list+=("$DOCKER_MNT")
df -hT "${df_list[@]}"
[[ $fail -eq 0 ]] && ok "STORAGE VALIDATION PASSED" || { echo "STORAGE VALIDATION FAILED"; exit 1; }
