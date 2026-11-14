#!/usr/bin/env bash
# MEMBER 1 - Package management: installs every package the server needs.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root; detect_pm

if [[ $PM == apt ]]; then
  apt-get update -y
  PKGS=(git vim curl wget tar rsync lvm2 parted xfsprogs e2fsprogs acl openssh-server
        chrony htop tmux tree net-tools iproute2 python3 build-essential cron
        ufw logrotate sysstat openssl fail2ban)
else
  dnf install -y epel-release 2>/dev/null || true
  PKGS=(git vim curl wget tar rsync lvm2 parted xfsprogs e2fsprogs acl openssh-server
        chrony htop tmux tree net-tools iproute python3 gcc make cronie
        firewalld logrotate sysstat openssl fail2ban)
fi

for p in "${PKGS[@]}"; do
  if pkg_install "$p" >/dev/null 2>&1; then ok "installed $p"; else warn "could not install $p (continuing)"; fi
done

log "Package installation finished ($PM)"
echo "--- version check ---"
git --version; python3 --version; lvm version | head -1
