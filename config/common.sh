#!/usr/bin/env bash
# Shared helper functions. Every script does:  source ".../config/common.sh"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/config/project.conf"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log()  { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOG_DIR/project.log" 2>/dev/null; }
ok()   { echo -e "\e[32m[ OK ]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
die()  { echo -e "\e[31m[FAIL]\e[0m $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"; }

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf >/dev/null 2>&1; then PM=dnf
  else die "Unsupported distro (need apt or dnf)"; fi
}

pkg_install() {
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
  esac
}

# service name differs between Debian-family and RHEL-family
svc_ssh()  { systemctl list-unit-files | grep -q '^sshd.service' && echo sshd || echo ssh; }
svc_cron() { systemctl list-unit-files | grep -q '^crond.service' && echo crond || echo cron; }

# ---- storage helpers ----
get_storage_devices() {   # prints the base block devices that hold the LVM partitions
  if [[ "$LAB_MODE" == "loop" ]]; then
    for img in "$LOOP_DIR"/disk*.img; do
      [[ -f "$img" ]] && losetup -j "$img" | cut -d: -f1
    done
  else
    for d in $DISKS; do echo "$d"; done
  fi
}
part_of() {               # /dev/loop0 -> /dev/loop0p1 ; /dev/sdb -> /dev/sdb1
  local d="$1"
  if [[ "$d" =~ [0-9]$ ]]; then echo "${d}p1"; else echo "${d}1"; fi
}
