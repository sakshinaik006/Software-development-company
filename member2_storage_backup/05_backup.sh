#!/usr/bin/env bash
# MEMBER 2 - Backup: compressed tar of repos, projects, /etc, /home + SHA256 checksum + retention.
# IDEMPOTENT: if a valid backup already exists for today, it is skipped (use --force to override).
# Safe to run from cron AND by hand: a lock prevents two runs overlapping.
# Usage: sudo bash 05_backup.sh [--force]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
FORCE=0; [[ "$1" == "--force" ]] && FORCE=1

# 1) EXIT if another backup is already running
exec 9>/var/lock/devserver-backup.lock
flock -n 9 || { log "BACKUP SKIPPED: another backup is still running"; exit 0; }

# 2) EXIT if the backup volume is not mounted (never fill the root disk)
mountpoint -q "$BACKUP_MNT" || { log "BACKUP ABORTED: $BACKUP_MNT not mounted"; die "$BACKUP_MNT is not mounted - aborting"; }
mkdir -p "$BACKUP_DIR"

# 3) EXIT if today's backup already exists AND its checksum is valid  (removes redundancy)
TODAY="$(date +%F)"
last="$(ls -1t "$BACKUP_DIR"/backup_"${TODAY}"_*.tar.gz 2>/dev/null | head -1)"
if [[ $FORCE -eq 0 && -n "$last" ]] && ( cd "$BACKUP_DIR" && sha256sum -c "$(basename "$last").sha256" >/dev/null 2>&1 ); then
  log "BACKUP SKIPPED: valid backup for $TODAY already exists ($(basename "$last"))"
  ok "already backed up today: $last"
  exit 0
fi

# 4) Take the backup into a .part file, rename only when complete (no half-written 'valid' files)
TS="$(date +%F_%H%M%S)"
FILE="$BACKUP_DIR/backup_${TS}.tar.gz"
SRC=(); for s in $BACKUP_SRC; do [[ -e "$s" ]] && SRC+=("$s"); done
tar --exclude='*/.cache' --exclude='*/node_modules' -czf "$FILE.part" "${SRC[@]}" 2>"$LOG_DIR/backup_last.err"
rc=$?
if [[ $rc -gt 1 ]]; then   # rc=1 only means "a file changed while being read" - acceptable
  rm -f "$FILE.part"; log "BACKUP FAILED (tar rc=$rc)"; die "backup failed, see $LOG_DIR/backup_last.err"
fi
mv "$FILE.part" "$FILE"

( cd "$BACKUP_DIR" && sha256sum "$(basename "$FILE")" > "$(basename "$FILE").sha256" )
find "$BACKUP_DIR" -name 'backup_*' -mtime +"$RETENTION_DAYS" -delete   # retention policy
log "BACKUP OK: $FILE ($(du -h "$FILE" | cut -f1)), kept last $RETENTION_DAYS days"
ok "backup created: $FILE"

# 5) Off-site copy (only if enabled in project.conf)
if [[ "$CLOUD_ENABLE" == "yes" ]]; then
  bash "$(dirname "${BASH_SOURCE[0]}")/08_cloud_sync.sh" "$FILE" || warn "cloud sync failed (local backup is fine)"
fi
exit 0
