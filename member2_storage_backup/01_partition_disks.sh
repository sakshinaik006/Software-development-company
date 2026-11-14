#!/usr/bin/env bash
# MEMBER 2 - Disk partitioning (GPT, one LVM partition per disk).
# loop mode : creates sparse image files and attaches them as virtual disks (safe).
# disk mode : partitions the real disks in $DISKS (destroys data!).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

if [[ "$LAB_MODE" == "loop" ]]; then
  mkdir -p "$LOOP_DIR"
  for i in $(seq 1 "$LOOP_DISK_COUNT"); do
    img="$LOOP_DIR/disk$i.img"
    [[ -f "$img" ]] || { truncate -s "$LOOP_DISK_SIZE" "$img"; ok "created $img ($LOOP_DISK_SIZE sparse)"; }
  done

  # helper + systemd unit so the virtual disks re-attach after reboot
  cat > /usr/local/sbin/lab-loop-attach.sh <<EOT
#!/bin/bash
for img in $LOOP_DIR/disk*.img; do
  losetup -j "\$img" | grep -q . || losetup -fP "\$img"
done
udevadm settle
vgchange -ay $VG_NAME >/dev/null 2>&1 || true
EOT
  chmod +x /usr/local/sbin/lab-loop-attach.sh
  cat > /etc/systemd/system/lab-loopdisks.service <<'EOT'
[Unit]
Description=Attach virtual disks for LVM lab
DefaultDependencies=no
After=systemd-udevd.service
Before=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lab-loop-attach.sh

[Install]
WantedBy=local-fs.target
EOT
  systemctl daemon-reload; systemctl enable lab-loopdisks.service >/dev/null 2>&1
  /usr/local/sbin/lab-loop-attach.sh
else
  lsblk
  echo "About to PARTITION (destroy data on): $DISKS"
  read -r -p "Type YES to continue: " a; [[ "$a" == "YES" ]] || die "aborted"
fi

for dev in $(get_storage_devices); do
  part="$(part_of "$dev")"
  if [[ -b "$part" ]]; then ok "$dev already partitioned ($part)"; continue; fi
  parted -s "$dev" mklabel gpt mkpart primary 1MiB 100% set 1 lvm on
  partprobe "$dev" 2>/dev/null || true
  partx -u "$dev" 2>/dev/null || partx -a "$dev" 2>/dev/null || true
  udevadm settle; sleep 1
  ok "partitioned $dev -> $part"
done
lsblk
log "Partitioning complete"
