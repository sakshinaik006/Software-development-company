#!/usr/bin/env bash
# MEMBER 1 - User & group administration: creates dev01..dev40 in the 'developers' group.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root

getent group "$DEV_GROUP" >/dev/null || { groupadd "$DEV_GROUP"; ok "group $DEV_GROUP created"; }

# Default files every new developer receives
mkdir -p /etc/skel
cat > /etc/skel/WELCOME.txt <<EOT
Welcome to $HOSTNAME_NEW (development server).
 - Shared projects : $PROJECTS_MNT
 - Git repositories: $REPOS_MNT   (git clone ssh://$(hostname)$REPOS_MNT/<name>.git)
 - Docker + Swarm : docker run / docker stack deploy   (rules: $PROJECTS_MNT/shared-tools/docker/README.txt)
 - Change your temporary password at first login.
EOT

touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
created=0
for i in $(seq -w 1 "$DEV_COUNT"); do
  u="${DEV_PREFIX}${i}"
  if id "$u" >/dev/null 2>&1; then continue; fi
  useradd -m -s /bin/bash -g "$DEV_GROUP" -c "Developer $i" "$u"
  pw="$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)"
  echo "$u:$pw" | chpasswd
  chage -d 0 "$u"                     # force password change at first login
  chage -M 90 -W 7 "$u"               # password expires after 90 days
  chmod 700 "/home/$u"                # other developers cannot read your home
  echo "$u  $pw" >> "$CRED_FILE"
  created=$((created+1))
done

ok "$created new users created. Total in group: $(getent passwd | awk -F: -v g="$(getent group $DEV_GROUP | cut -d: -f3)" '$4==g' | wc -l)"
ok "Temporary passwords saved in $CRED_FILE (root only)"
log "User creation done ($created new)"
