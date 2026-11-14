#!/usr/bin/env bash
# MEMBER 3 - Firewall: default-deny incoming; allow SSH (rate-limited) and the dashboard port.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')"; SSH_PORT="${SSH_PORT:-22}"

if command -v ufw >/dev/null 2>&1; then
  ufw --force reset >/dev/null
  ufw default deny incoming; ufw default allow outgoing
  ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate limited)'     # allow SSH FIRST to avoid lock-out
  ufw allow "${DASH_PORT}/tcp" comment 'Dashboard'
  for p in $SWARM_PEERS; do   # swarm cluster traffic ONLY from listed peer nodes
    ufw allow from "$p" to any port 2377 proto tcp comment 'Swarm management'
    ufw allow from "$p" to any port 7946 comment 'Swarm node gossip'
    ufw allow from "$p" to any port 4789 proto udp comment 'Swarm overlay network'
  done
  ufw --force enable
  ufw status verbose
elif command -v firewall-cmd >/dev/null 2>&1; then
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-port="${DASH_PORT}/tcp"
  for p in $SWARM_PEERS; do
    for r in "2377 tcp" "7946 tcp" "7946 udp" "4789 udp"; do set -- $r
      firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$p port port=$1 protocol=$2 accept"
    done
  done
  firewall-cmd --reload; firewall-cmd --list-all
else
  die "no ufw/firewalld found - run member1 01_install_packages.sh"
fi
log "Firewall configured (ssh:$SSH_PORT dashboard:$DASH_PORT)"
