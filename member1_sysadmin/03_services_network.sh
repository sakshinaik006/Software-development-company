#!/usr/bin/env bash
# MEMBER 1 - Service configuration & networking.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

# --- hostname ---
hostnamectl set-hostname "$HOSTNAME_NEW" 2>/dev/null || hostname "$HOSTNAME_NEW"
grep -q "$HOSTNAME_NEW" /etc/hosts || echo "127.0.1.1  $HOSTNAME_NEW" >> /etc/hosts

# --- enable and start services ---
for s in "$(svc_ssh)" "$(svc_cron)" chrony chronyd; do
  if systemctl list-unit-files | grep -q "^${s}.service"; then
    systemctl enable --now "$s" >/dev/null 2>&1 && ok "service $s enabled & running" || warn "service $s failed"
  fi
done

# --- login banner ---
cat > /etc/issue.net <<EOT
*** $HOSTNAME_NEW - Authorized developers only. Activity is monitored. ***
EOT

# --- network report ---
REPORT="$LOG_DIR/network_report.txt"
{
  echo "== Network report $(date) =="
  echo "-- Hostname: $(hostname)"
  echo "-- Interfaces"; ip -br addr
  echo "-- Routes";     ip route
  echo "-- DNS";        grep -E '^(nameserver|search)' /etc/resolv.conf
  echo "-- Listening ports"; ss -tulnp 2>/dev/null | head -20
  echo "-- Connectivity"
  ping -c2 -W2 8.8.8.8 >/dev/null 2>&1 && echo "Internet (IP)  : OK" || echo "Internet (IP)  : FAIL"
  getent hosts github.com >/dev/null 2>&1 && echo "DNS resolution : OK" || echo "DNS resolution : FAIL"
} | tee "$REPORT"

cat <<'EOT'

NOTE (static IP): On Ubuntu edit /etc/netplan/00-installer-config.yaml, e.g.
  network:
    version: 2
    ethernets:
      enp0s3:
        addresses: [192.168.1.50/24]
        routes: [{to: default, via: 192.168.1.1}]
        nameservers: {addresses: [8.8.8.8, 1.1.1.1]}
then run:  sudo netplan apply
On RHEL/CentOS use: nmcli con mod <name> ipv4.addresses 192.168.1.50/24 ipv4.method manual
EOT
log "Services & network configured"
