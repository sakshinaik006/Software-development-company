#!/usr/bin/env bash
# MEMBER 3 - Server monitoring: CPU, memory, load, disk, users, failed logins -> log + ALERT lines.
# Run by cron every 5 minutes. Output: $LOG_DIR/monitor.log
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
OUT="$LOG_DIR/monitor.log"; mkdir -p "$LOG_DIR"

read -ra a < <(head -1 /proc/stat); sleep 1; read -ra b < <(head -1 /proc/stat)
ta=0; tb=0; for v in "${a[@]:1:8}"; do ta=$((ta+v)); done; for v in "${b[@]:1:8}"; do tb=$((tb+v)); done
ia=$((a[4]+a[5])); ib=$((b[4]+b[5])); dt=$((tb-ta))
CPU=0; [[ $dt -gt 0 ]] && CPU=$(( 100 * (dt - (ib-ia)) / dt ))
MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d",(t-a)*100/t}' /proc/meminfo)
LOAD=$(cut -d' ' -f1 /proc/loadavg)
USERS=$(who | wc -l)
DOCK=""; [[ "$DOCKER_ENABLE" == "yes" ]] && command -v docker >/dev/null 2>&1 && DOCK=" containers=$(docker ps -q 2>/dev/null | wc -l)"

line="$(date '+%F %T') cpu=${CPU}% mem=${MEM}% load=${LOAD} users=${USERS}${DOCK}"
for m in / "$REPOS_MNT" "$PROJECTS_MNT" "$BACKUP_MNT" "$DOCKER_MNT"; do
  mountpoint -q "$m" || [[ "$m" == "/" ]] || continue
  u=$(df --output=pcent "$m" | tail -1 | tr -dc 0-9); line+=" disk[$m]=${u}%"
  [[ ${u:-0} -ge $DISK_ALERT ]] && echo "$(date '+%F %T') ALERT disk $m at ${u}%" >> "$OUT"
done
echo "$line" >> "$OUT"
[[ ${CPU:-0} -ge $CPU_ALERT ]] && echo "$(date '+%F %T') ALERT cpu at ${CPU}%" >> "$OUT"
[[ ${MEM:-0} -ge $MEM_ALERT ]] && echo "$(date '+%F %T') ALERT memory at ${MEM}%" >> "$OUT"
awk -v l="$LOAD" -v t="$LOAD_ALERT" 'BEGIN{exit !(l>=t)}' && echo "$(date '+%F %T') ALERT load average $LOAD" >> "$OUT"
for s in "$(svc_ssh)" "$(svc_cron)"; do systemctl is-active --quiet "$s" || echo "$(date '+%F %T') ALERT service $s is DOWN" >> "$OUT"; done
[[ "$DOCKER_ENABLE" == "yes" ]] && command -v docker >/dev/null 2>&1 && { systemctl is-active --quiet docker || echo "$(date '+%F %T') ALERT service docker is DOWN" >> "$OUT"; }
if [[ "$SWARM_ENABLE" == "yes" ]] && command -v docker >/dev/null 2>&1 && [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == "active" ]]; then
  docker service ls --format '{{.Name}} {{.Mode}} {{.Replicas}}' 2>/dev/null | awk '($2=="replicated"||$2=="global"){split($3,r,"/"); if (r[1]!=r[2]) print $1, $3}' |
    while read -r n r; do echo "$(date '+%F %T') ALERT swarm service $n has replicas $r" >> "$OUT"; done
  docker node ls --format '{{.Hostname}} {{.Status}}' 2>/dev/null | awk '$2!="Ready"{print $1, $2}' |
    while read -r n s; do echo "$(date '+%F %T') ALERT swarm node $n is $s" >> "$OUT"; done
fi
tail -1 "$OUT"
