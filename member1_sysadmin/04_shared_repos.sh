#!/usr/bin/env bash
# MEMBER 1 - Shared repositories and project folders (run AFTER Member 2 mounted the LVM volumes).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

mountpoint -q "$REPOS_MNT" || warn "$REPOS_MNT is not a separate mount - run member2 scripts first for the LVM layout"
mkdir -p "$REPOS_MNT" "$PROJECTS_MNT"

# let git work on group-shared repositories owned by different users
git config --system --add safe.directory '*' 2>/dev/null || true

for p in $PROJECTS; do
  repo="$REPOS_MNT/project-$p.git"
  if [[ ! -d "$repo" ]]; then
    git init --bare --shared=group "$repo" >/dev/null
    ok "bare repo created: $repo"
  fi
  mkdir -p "$PROJECTS_MNT/$p"
done
mkdir -p "$PROJECTS_MNT/shared-tools"

chown -R root:"$DEV_GROUP" "$REPOS_MNT" "$PROJECTS_MNT"
chmod 2775 "$REPOS_MNT" "$PROJECTS_MNT"
find "$REPOS_MNT" "$PROJECTS_MNT" -mindepth 1 -type d -exec chmod 2775 {} +
# default ACL: new files automatically group-writable for developers
setfacl -R -m g:"$DEV_GROUP":rwx "$REPOS_MNT" "$PROJECTS_MNT" 2>/dev/null
setfacl -R -d -m g:"$DEV_GROUP":rwx "$REPOS_MNT" "$PROJECTS_MNT" 2>/dev/null

ls -la "$REPOS_MNT" "$PROJECTS_MNT"
log "Shared repositories ready"
