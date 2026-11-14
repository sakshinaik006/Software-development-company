#!/usr/bin/env bash
# MEMBER 2 - LVM: Physical Volumes -> Volume Group -> Logical Volumes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

PVS=()
for dev in $(get_storage_devices); do
  part="$(part_of "$dev")"; [[ -b "$part" ]] || die "$part missing - run 01_partition_disks.sh first"
  pvs "$part" >/dev/null 2>&1 || pvcreate -y "$part"
  pvresize "$part" >/dev/null 2>&1 || true
  PVS+=("$part")
done

if vgs "$VG_NAME" >/dev/null 2>&1; then
  for p in "${PVS[@]}"; do
    pvs --noheadings -o vg_name "$p" 2>/dev/null | grep -qw "$VG_NAME" || vgextend "$VG_NAME" "$p" 2>/dev/null || true
  done
else
  vgcreate "$VG_NAME" "${PVS[@]}"
fi

mklv() {
  local name="$1" size="$2"
  if ! lvs "$VG_NAME/$name" >/dev/null 2>&1; then
    lvcreate -y -L "$size" -n "$name" "$VG_NAME" || lvcreate -y -l 100%FREE -n "$name" "$VG_NAME"
  fi
}
mklv "$LV_REPOS"    "$LV_REPOS_SIZE"
mklv "$LV_PROJECTS" "$LV_PROJECTS_SIZE"
mklv "$LV_BACKUP"   "$LV_BACKUP_SIZE"
[[ "$DOCKER_ENABLE" == "yes" ]] && mklv "$LV_DOCKER" "$LV_DOCKER_SIZE"

echo "=== PV ==="; pvs; echo "=== VG ==="; vgs; echo "=== LV ==="; lvs
log "LVM configured"
