#!/usr/bin/env bash
# MEMBER 2 - File-system creation, mount points and persistent /etc/fstab entries.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

setup_fs() {  # lv  fstype  mountpoint
  local dev="/dev/$VG_NAME/$1" fs="$2" mnt="$3"
  [[ -e "$dev" ]] || die "$dev missing - run 02_lvm_setup.sh"
  blkid "$dev" >/dev/null 2>&1 || { mkfs -t "$fs" "$dev" >/dev/null && ok "mkfs.$fs on $dev"; }
  mkdir -p "$mnt"
  local opts="defaults,nofail"
  [[ "$LAB_MODE" == "loop" ]] && opts="$opts,x-systemd.requires=lab-loopdisks.service"
  grep -q " $mnt " /etc/fstab || echo "$dev  $mnt  $fs  $opts  0 2" >> /etc/fstab

  # Migrate existing data if directory is not empty and not yet mounted
  if ! mountpoint -q "$mnt"; then
    if [[ -d "$mnt" ]] && [[ -n "$(ls -A "$mnt" 2>/dev/null)" ]]; then
      log "Migrating existing data in $mnt to $dev..."
      local stopped_docker=0
      if [[ "$mnt" == "$DOCKER_MNT" ]] && systemctl is-active --quiet docker; then
        systemctl stop docker.service docker.socket 2>/dev/null || true
        stopped_docker=1
      fi
      local tmp_mnt="/mnt/tmp_migrate_$(basename "$mnt")"
      mkdir -p "$tmp_mnt"
      mount "$dev" "$tmp_mnt"
      cp -a "$mnt"/. "$tmp_mnt"/ 2>/dev/null || true
      umount "$tmp_mnt"
      rmdir "$tmp_mnt" 2>/dev/null || true
      mount "$dev" "$mnt" && ok "mounted $dev on $mnt (migrated data preserved)"
      if [[ $stopped_docker -eq 1 ]]; then
        systemctl start docker.service 2>/dev/null || true
      fi
    else
      mount "$dev" "$mnt" 2>/dev/null || true
    fi
  fi
}
setup_fs "$LV_REPOS"    "$REPOS_FS"    "$REPOS_MNT"
setup_fs "$LV_PROJECTS" "$PROJECTS_FS" "$PROJECTS_MNT"
setup_fs "$LV_BACKUP"   "$BACKUP_FS"   "$BACKUP_MNT"
[[ "$DOCKER_ENABLE" == "yes" ]] && setup_fs "$LV_DOCKER" "$DOCKER_FS" "$DOCKER_MNT"   # mount BEFORE Docker is installed

systemctl daemon-reload
mount -a && ok "mount -a succeeded"
mkdir -p "$BACKUP_DIR"; chmod 750 "$BACKUP_MNT"
df_list=("$REPOS_MNT" "$PROJECTS_MNT" "$BACKUP_MNT")
[[ "$DOCKER_ENABLE" == "yes" ]] && df_list+=("$DOCKER_MNT")
df -hT "${df_list[@]}"
log "Filesystems mounted"
