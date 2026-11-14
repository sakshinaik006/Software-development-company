#!/usr/bin/env bash
# MEMBER 3 - System security hardening (SSH, fail2ban, kernel parameters).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

# --- SSH (drop-in file; validated before reload so we can never lock ourselves out) ---
mkdir -p /etc/ssh/sshd_config.d
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config 2>/dev/null || echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/99-devserver.conf <<EOT
PermitRootLogin no
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/issue.net
EOT
if sshd -t 2>/dev/null; then systemctl reload "$(svc_ssh)" && ok "SSH hardened"; else rm -f /etc/ssh/sshd_config.d/99-devserver.conf; warn "sshd config invalid - reverted"; fi

# --- fail2ban: ban IPs after repeated SSH failures ---
if command -v fail2ban-client >/dev/null 2>&1; then
  cat > /etc/fail2ban/jail.local <<EOT
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
EOT
  systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban active"
fi

# --- kernel / network hardening ---
cat > /etc/sysctl.d/99-devserver.conf <<EOT
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.randomize_va_space = 2
EOT
sysctl --system >/dev/null && ok "sysctl hardening applied"

# --- password quality / lock accounts without password ---
awk -F: '($2=="" ){print "WARNING: empty password for " $1}' /etc/shadow
log "Security hardening applied"
