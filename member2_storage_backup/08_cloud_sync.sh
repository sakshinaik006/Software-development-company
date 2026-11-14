#!/usr/bin/env bash
# MEMBER 2 - Copy backups to cloud storage (S3 / Azure / GCS / Google Drive ...) using rclone.
# One-time setup:  curl https://rclone.org/install.sh | sudo bash ; sudo rclone config
#                  then set CLOUD_ENABLE="yes" and CLOUD_REMOTE="<remote>:<bucket>" in config/project.conf
# Usage: sudo bash 08_cloud_sync.sh [backup_file]     (default: newest local backup)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
[[ "$CLOUD_ENABLE" == "yes" ]] || { log "cloud sync disabled (CLOUD_ENABLE=no)"; exit 0; }
command -v rclone >/dev/null || die "rclone not installed:  curl https://rclone.org/install.sh | sudo bash"

FILE="${1:-$(ls -1t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -1)}"
[[ -f "$FILE" ]] || die "no local backup to upload"
name="$(basename "$FILE")"

# EXIT if this exact file is already in the cloud (no duplicate uploads)
if rclone lsf "$CLOUD_REMOTE" --include "$name" 2>/dev/null | grep -qx "$name"; then
  log "CLOUD SKIPPED: $name already uploaded"; ok "already in cloud: $name"; exit 0
fi

rclone copy "$FILE" "$CLOUD_REMOTE" && rclone copy "$FILE.sha256" "$CLOUD_REMOTE" \
  || { log "CLOUD UPLOAD FAILED: $name"; die "upload failed"; }
log "CLOUD OK: $name -> $CLOUD_REMOTE"

# cloud retention
rclone delete "$CLOUD_REMOTE" --min-age "${CLOUD_KEEP_DAYS}d" --include "backup_*" 2>/dev/null
ok "uploaded $name to $CLOUD_REMOTE"
