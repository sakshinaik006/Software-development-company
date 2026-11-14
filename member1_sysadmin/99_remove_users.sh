#!/usr/bin/env bash
# MEMBER 1 - ROLLBACK helper: deletes dev01..dev40 and their home directories.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
read -r -p "Delete ALL ${DEV_PREFIX}NN users and home dirs? type YES: " a
[[ "$a" == "YES" ]] || die "aborted"
for i in $(seq -w 1 "$DEV_COUNT"); do userdel -r "${DEV_PREFIX}${i}" 2>/dev/null; done
groupdel "$DEV_GROUP" 2>/dev/null; rm -f "$CRED_FILE"
ok "users removed"
