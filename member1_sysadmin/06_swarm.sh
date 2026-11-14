#!/usr/bin/env bash
# MEMBER 1 - Orchestration with Docker Swarm: manager node, overlay network, private registry,
#            shared stack folder and a demo stack. Run AFTER 05_docker.sh. Safe to re-run.
# Single server today; add worker nodes (e.g. cloud VMs) any time - see the end of this script's output.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
[[ "$DOCKER_ENABLE" == "yes" && "$SWARM_ENABLE" == "yes" ]] || { log "Swarm disabled in project.conf - skipped"; exit 0; }
command -v docker >/dev/null 2>&1 || die "Docker is not installed - run member1_sysadmin/05_docker.sh first"
docker info >/dev/null 2>&1 || die "Docker daemon is not running"

# ---------- 1) initialise the swarm (this server = manager) ----------
state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
if [[ "$state" == "active" ]]; then
  ok "swarm already active"
else
  ADDR="${SWARM_ADVERTISE_ADDR:-$(hostname -I | awk '{print $1}')}"
  [[ -n "$ADDR" ]] || die "cannot detect the server IP - set SWARM_ADVERTISE_ADDR in config/project.conf"
  if docker swarm init --advertise-addr "$ADDR" >/dev/null 2>&1; then ok "swarm initialised - this server is the manager ($ADDR)"
  else die "swarm init failed (is live-restore still in /etc/docker/daemon.json? re-run 05_docker.sh) - try: docker swarm init --advertise-addr $ADDR"; fi
fi

# ---------- 2) shared overlay network for developer stacks ----------
docker network inspect "$SWARM_NET" >/dev/null 2>&1 || docker network create -d overlay --attachable "$SWARM_NET" >/dev/null \
  && ok "overlay network '$SWARM_NET' ready"

# ---------- 3) private registry (so images built here can be deployed as stacks) ----------
if [[ "$REGISTRY_ENABLE" == "yes" ]]; then
  if docker ps -a --format '{{.Names}}' | grep -qx registry; then
    docker start registry >/dev/null 2>&1; ok "private registry already present (localhost:5000)"
  elif docker run -d --name registry --restart always -p 127.0.0.1:5000:5000 \
        -v registry-data:/var/lib/registry --label owner=admin registry:2 >/dev/null 2>&1; then
    ok "private registry running on localhost:5000"
  else
    warn "could not start the registry (no internet to pull registry:2?)"
  fi
fi

# ---------- 4) shared folder for stack files + rules for developers ----------
mkdir -p "$STACKS_DIR"
cat > "$STACKS_DIR/README.txt" <<EOD
DEPLOYING APPLICATIONS ON THE SWARM  ($HOSTNAME_NEW)
---------------------------------------------------------------
Build + publish   docker build -t localhost:5000/\$USER/app:1.0 .   &&   docker push localhost:5000/\$USER/app:1.0
Deploy            docker stack deploy -c mystack.yml \$USER-app        (stack name starts with your username)
Inspect           docker stack ls | docker service ls | docker service ps \$USER-app_web
Logs              docker service logs -f \$USER-app_web
Scale             docker service scale \$USER-app_web=4
Rolling update    docker service update --image localhost:5000/\$USER/app:1.1 \$USER-app_web
Rollback          docker service rollback \$USER-app_web
Remove            docker stack rm \$USER-app

Rules
 1. Start from $STACKS_DIR/demo.yml. Always set deploy.resources.limits and a healthcheck.
 2. Join the shared network:  networks: { $SWARM_NET: { external: true } }
 3. Published ports: use 9000-9999 only. Swarm publishes them on EVERY interface of EVERY node and
    Docker bypasses the firewall, so publish only what must be reachable.
 4. Never put passwords in stack files - use:  echo -n 's3cret' | docker secret create db_pass -
 5. Keep your stack files in your project's Git repo or in $STACKS_DIR/<username>/.
 6. Never run: docker swarm leave / docker node rm / docker system prune -a   (they affect everybody).
 7. The registry on localhost:5000 is reachable from this server only.
EOD

cat > "$STACKS_DIR/demo.yml" <<EOD
version: "3.8"
services:
  web:
    image: nginx:alpine
    ports:
      - "9080:80"
    networks: [$SWARM_NET]
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/ >/dev/null || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 2s
    deploy:
      replicas: 2
      resources:
        limits: { cpus: "0.50", memory: 128M }
      restart_policy: { condition: on-failure }
      update_config: { parallelism: 1, delay: 5s, order: start-first }
networks:
  $SWARM_NET:
    external: true
EOD
chown -R root:"$DEV_GROUP" "$STACKS_DIR"; chmod 2775 "$STACKS_DIR"; find "$STACKS_DIR" -type f -exec chmod 664 {} +

# ---------- 5) demo stack (proves scheduling, load-balancing and the overlay network) ----------
docker stack rm demo >/dev/null 2>&1 || true
sleep 2
if docker stack deploy -c "$STACKS_DIR/demo.yml" demo >/dev/null 2>&1; then
  for _ in $(seq 1 30); do
    [[ "$(docker service ls --filter name=demo_web --format '{{.Replicas}}')" == "2/2" ]] && break; sleep 2
  done
  for _ in $(seq 1 15); do
    curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:9080 2>/dev/null && break || sleep 1
  done
  ok "demo stack deployed: $(docker service ls --filter name=demo_web --format '{{.Name}} {{.Replicas}}')  ->  http://$(hostname -I | awk '{print $1}'):9080"
else
  warn "demo stack could not be deployed (images need internet) - check: docker stack ps demo"
fi

echo; docker node ls; echo; docker service ls
cat <<'EOT2'

ADD A WORKER NODE (another VM / cloud server with Docker installed):
  1. On the worker, allow this server on 2377/tcp, 7946/tcp+udp, 4789/udp.
  2. On THIS server list the worker IP in SWARM_PEERS (config/project.conf) and re-run 03_firewall.sh.
  3. Print the join command (it contains a secret token - do not paste it in chat or logs):
         docker swarm join-token worker
  4. Run that printed command on the worker.  Check:  docker node ls
EOT2
log "Swarm orchestration configured"
