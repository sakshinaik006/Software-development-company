#!/usr/bin/env bash
# MEMBER 2 - Recovery: verify checksum, then extract a backup.
# Usage: sudo bash 06_restore.sh [backup_file] [target_dir]
#   defaults: newest backup -> /tmp/restore_test   (use target "/" for a real restore)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
FILE="${1:-$(ls -1t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -1)}"
TARGET="${2:-/tmp/restore_test}"
[[ -f "$FILE" ]] || die "no backup file found"

echo "Verifying checksum..."
( cd "$(dirname "$FILE")" && sha256sum -c "$(basename "$FILE").sha256" ) || die "CHECKSUM MISMATCH - backup corrupt"
mkdir -p "$TARGET"
tar -xzf "$FILE" -C "$TARGET" && ok "restored $FILE -> $TARGET"
echo "Restored top-level content:"; ls "$TARGET"
log "RESTORE OK: $FILE -> $TARGET"
