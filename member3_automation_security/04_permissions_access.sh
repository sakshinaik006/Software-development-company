#!/usr/bin/env bash
# MEMBER 3 - Permissions & access control.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

chmod 2775 "$REPOS_MNT" "$PROJECTS_MNT" 2>/dev/null          # shared, setgid -> group inherited
chown root:"$DEV_GROUP" "$REPOS_MNT" "$PROJECTS_MNT"
chmod 750 "$BACKUP_MNT"; chown root:root "$BACKUP_MNT"       # developers cannot touch backups
chmod 600 "$CRED_FILE" 2>/dev/null
chmod 700 /root
chmod 640 /etc/shadow 2>/dev/null; chmod 644 /etc/passwd

# home directories private
for h in /home/${DEV_PREFIX}*; do [[ -d "$h" ]] && chmod 700 "$h"; done

# default umask for new accounts (group can read, others cannot)
sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs
grep -q '^HOME_MODE' /etc/login.defs && sed -i 's/^HOME_MODE.*/HOME_MODE       0700/' /etc/login.defs

# developers get NO sudo; only members of the sudo/wheel group do
for g in sudo wheel; do getent group $g >/dev/null && echo "group $g members: $(getent group $g | cut -d: -f4)"; done

# limited sudo: developers may only inspect services/logs
cat > /etc/sudoers.d/developers <<EOT
%$DEV_GROUP ALL=(root) NOPASSWD: /usr/bin/systemctl status *, /usr/bin/journalctl
EOT
chmod 440 /etc/sudoers.d/developers
visudo -cf /etc/sudoers.d/developers || { rm -f /etc/sudoers.d/developers; die "invalid sudoers file removed"; }

echo "--- world-writable files outside /tmp (should be empty) ---"
find / -xdev -type f -perm -0002 -not -path '/proc/*' -not -path '/tmp/*' -not -path '/var/tmp/*' 2>/dev/null | head
echo "--- SUID binaries ---"; find / -xdev -perm -4000 -type f 2>/dev/null | head -20
log "Permissions & access control applied"
