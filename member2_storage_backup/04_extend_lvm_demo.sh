#!/usr/bin/env bash
# MEMBER 2 - Storage allocation demo: grow a logical volume ONLINE (no downtime).
# Usage: sudo bash 04_extend_lvm_demo.sh [lv_name] [size]   default: lv_repos +500M
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
LV="${1:-$LV_REPOS}"; SIZE="${2:-+500M}"
echo "--- BEFORE ---"; lvs "$VG_NAME/$LV"; df -h "/dev/$VG_NAME/$LV" | tail -1
vgs --noheadings -o vg_free "$VG_NAME" | xargs echo "VG free space:"
lvextend -r -L "$SIZE" "/dev/$VG_NAME/$LV"      # -r resizes the filesystem too
echo "--- AFTER ---";  lvs "$VG_NAME/$LV"; df -h "/dev/$VG_NAME/$LV" | tail -1
log "Extended $LV by $SIZE"
