#!/usr/bin/env bash
# MEMBER 1 - Core of the server - shared Docker host: installs Docker Engine, hardens the daemon, gives every developer access.
# Run AFTER member2 03_filesystems_mount.sh so /var/lib/docker is its own LVM volume.
# Safe to re-run (idempotent) - re-run it after adding new developers so they join the docker group.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root; detect_pm
[[ "$DOCKER_ENABLE" == "yes" ]] || { log "Docker disabled in project.conf - skipped"; exit 0; }

mountpoint -q "$DOCKER_MNT" || warn "$DOCKER_MNT is not a separate volume - images will fill the root disk (run the member2 storage scripts first)"

# ---------- 1) install Docker Engine ----------
if ! command -v docker >/dev/null 2>&1; then
  ok "installing Docker Engine (needs internet) ..."
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh >/tmp/docker-install.log 2>&1; then
    ok "Docker installed from the official repository"
  elif [[ $PM == apt ]] && pkg_install docker.io >/tmp/docker-install.log 2>&1; then
    warn "official installer failed - installed distro package docker.io instead"
  else
    die "Docker installation failed - see /tmp/docker-install.log"
  fi
fi
docker compose version >/dev/null 2>&1 || pkg_install docker-compose-plugin >/dev/null 2>&1 || pkg_install docker-compose-v2 >/dev/null 2>&1 || warn "Docker Compose plugin not installed"

# ---------- 2) hardened daemon configuration ----------
mkdir -p /etc/docker
[[ -f /etc/docker/daemon.json && ! -f /etc/docker/daemon.json.orig ]] && cp /etc/docker/daemon.json /etc/docker/daemon.json.orig
USERNS="$DOCKER_USERNS" LOGMAX="$DOCKER_LOG_MAX" SWARM="$SWARM_ENABLE" python3 - <<'PY'
import json, os
cfg = {
    "log-driver": "json-file",
    "log-opts": {"max-size": os.environ["LOGMAX"], "max-file": "3"},   # stop container logs filling the disk
    "no-new-privileges": True,               # containers cannot gain extra privileges via setuid binaries
    "ip": "127.0.0.1",                       # -p 8081:80 binds to localhost; use -p 0.0.0.0:8081:80 to expose deliberately
    "default-ulimits": {"nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}},
}
if os.environ["SWARM"] != "yes":
    cfg["live-restore"] = True               # containers survive a daemon restart (NOT allowed together with swarm mode)
if os.environ["USERNS"] == "yes":
    cfg["userns-remap"] = "default"          # container root -> unprivileged host uid
json.dump(cfg, open("/etc/docker/daemon.json", "w"), indent=2)
PY
systemctl enable docker >/dev/null 2>&1
if systemctl restart docker && docker info >/dev/null 2>&1; then
  ok "Docker daemon running with the hardened configuration"
else
  warn "Docker would not start with the new daemon.json - restoring previous config"
  if [[ -f /etc/docker/daemon.json.orig ]]; then cp /etc/docker/daemon.json.orig /etc/docker/daemon.json; else rm -f /etc/docker/daemon.json; fi
  systemctl restart docker; die "Docker failed to start - check: journalctl -u docker"
fi

# ---------- 3) every developer joins the docker group ----------
getent group "$DOCKER_GROUP" >/dev/null || groupadd "$DOCKER_GROUP"
GID="$(getent group "$DEV_GROUP" | cut -d: -f3)"
n=0
for u in $(getent passwd | awk -F: -v g="$GID" '$4==g {print $1}'); do
  id -nG "$u" | grep -qw "$DOCKER_GROUP" || { usermod -aG "$DOCKER_GROUP" "$u" && n=$((n+1)); }
done
ok "$n developer(s) added to group '$DOCKER_GROUP' (they must log out and back in once)"
warn "SECURITY: the '$DOCKER_GROUP' group is root-equivalent on this server. Only trusted developers should be in it."

# ---------- 4) shared quick-start for developers ----------
SH="$PROJECTS_MNT/shared-tools/docker"; mkdir -p "$SH"
cat > "$SH/README.txt" <<EOD
SHARED DOCKER on $HOSTNAME_NEW  -  one daemon, one image cache for all developers
------------------------------------------------------------------------------
Quick start        docker run --rm hello-world
Compose projects   keep them in $PROJECTS_MNT/<project>/ and run:  docker compose up -d

House rules (the daemon is shared - be a good neighbour)
 1. Name containers with your username:    --name ${DEV_PREFIX}01-web
 2. Label them so the dashboard shows you: --label owner=\$USER
 3. Set limits:                            --memory 1g --cpus 1
 4. Ports: published ports of plain containers bind to 127.0.0.1 by default. To expose one on the network use
    -p 0.0.0.0:9xxx:80  and stay in the range 9000-9999 (8080 is the dashboard).
    Swarm services are different: see $STACKS_DIR/README.txt (their ports are published on all interfaces).
 5. Never run 'docker system prune -a' or 'docker volume prune' - it affects everybody's work.
 6. Containers run with no-new-privileges by default. Override only if you must:
    --security-opt no-new-privileges=false
 7. Data you care about belongs in a named volume or a bind mount under $PROJECTS_MNT, not in the container layer.
    Old stopped containers (> $DOCKER_PRUNE_AGE) and unused images are removed every Sunday.
EOD
chown -R root:"$DEV_GROUP" "$SH"; chmod 2775 "$SH"; chmod 644 "$SH/README.txt"

# ---------- 5) smoke test ----------
if timeout 120 docker run --rm hello-world >/dev/null 2>&1; then ok "hello-world container ran successfully"
else warn "hello-world test failed (no internet / registry blocked?) - daemon itself is running"; fi
docker info --format 'Docker {{.ServerVersion}} | storage driver: {{.Driver}} | data root: {{.DockerRootDir}}'
log "Docker shared host configured ($n users added to $DOCKER_GROUP)"
