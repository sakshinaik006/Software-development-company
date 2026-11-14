#!/usr/bin/env bash
# MEMBER 3 - Automated cleanup of temporary files / caches / old core dumps.
# Usage: sudo bash 01_cleanup.sh [--dry-run]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
DRY=0; [[ "$1" == "--dry-run" ]] && DRY=1
before=$(df --output=used / | tail -1)

clean() {  # description  path  days  [extra find args]
  local desc="$1" path="$2" days="$3"; shift 3
  [[ -d "$path" ]] || return
  local n; n=$(find "$path" -xdev -type f -mtime +"$days" "$@" 2>/dev/null | wc -l)
  if [[ $DRY -eq 1 ]]; then echo "[dry-run] $desc: $n files would be deleted"
  else find "$path" -xdev -type f -mtime +"$days" "$@" -delete 2>/dev/null; log "cleanup: $desc -> $n files removed"; fi
}
clean "/tmp older than 7 days"          /tmp      7
clean "/var/tmp older than 14 days"     /var/tmp  14
clean "developer caches older than 30d" /home     30 -path '*/.cache/*'
clean "core dumps older than 7 days"    /var/crash 7
clean "old rotated logs (.gz > 30d)"    /var/log  30 -name '*.gz'
clean "project build leftovers (*.tmp, *.o, *.pyc > 30d)" "$PROJECTS_MNT" 30 \( -name '*.tmp' -o -name '*.o' -o -name '*.pyc' \)

# Docker: stopped containers, unused images and build cache older than $DOCKER_PRUNE_AGE. Volumes are NEVER pruned.
if [[ "$DOCKER_ENABLE" == "yes" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [[ $DRY -eq 1 ]]; then echo "[dry-run] docker disk usage:"; docker system df
  else
    docker container prune -f --filter "until=$DOCKER_PRUNE_AGE" >/dev/null 2>&1
    docker image prune -af --filter "until=$DOCKER_PRUNE_AGE" >/dev/null 2>&1
    docker builder prune -f --filter "until=$DOCKER_PRUNE_AGE" >/dev/null 2>&1
    log "cleanup: docker containers/images/build-cache older than $DOCKER_PRUNE_AGE pruned"
  fi
fi

[[ $DRY -eq 0 ]] && { after=$(df --output=used / | tail -1); log "cleanup finished, freed $(( (before-after)/1024 )) MB on /"; }
exit 0
