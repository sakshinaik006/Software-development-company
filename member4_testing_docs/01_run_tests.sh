#!/usr/bin/env bash
# MEMBER 4 - System testing: validates every requirement of the problem statement.
# Usage: sudo bash 01_run_tests.sh [--quiet]     Report: $LOG_DIR/test_report.txt (read by the dashboard)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)/common.sh"
require_root
QUIET=0; [[ "$1" == "--quiet" ]] && QUIET=1
REPORT="$LOG_DIR/test_report.txt"; : > "$REPORT"
PASS=0; FAIL=0
t() {  # "description" "command"
  if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS - $1" >> "$REPORT"; [[ $QUIET -eq 0 ]] && echo -e "\e[32mPASS\e[0m $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1" >> "$REPORT"; [[ $QUIET -eq 0 ]] && echo -e "\e[31mFAIL\e[0m $1"; fi
}
GID=$(getent group "$DEV_GROUP" | cut -d: -f3)
NUSERS=$(getent passwd | awk -F: -v g="$GID" '$4==g' | wc -l)

echo "### Member 1 - System administration"
t "Group '$DEV_GROUP' exists"                          "getent group $DEV_GROUP"
t "$DEV_COUNT developer accounts exist ($NUSERS found)" "[ ${NUSERS:-0} -ge $DEV_COUNT ]"
t "Home directory of ${DEV_PREFIX}01 exists"           "[ -d /home/${DEV_PREFIX}01 ]"
t "Password aging set for ${DEV_PREFIX}01"             "chage -l ${DEV_PREFIX}01 | grep -q 'Maximum.*90'"
t "SSH service active"                                 "systemctl is-active --quiet $(svc_ssh)"
t "Time sync (chrony) installed"                       "command -v chronyc || systemctl list-unit-files | grep -q chrony"
t "Git installed"                                      "command -v git"
t "Hostname is $HOSTNAME_NEW"                          "[ \"\$(hostname)\" = $HOSTNAME_NEW ]"
t "Bare repositories exist in $REPOS_MNT"              "ls -d $REPOS_MNT/project-*.git"
t "Network: default route present"                     "ip route | grep -q default"

echo "### Member 2 - Storage & backup"
t "LVM volume group $VG_NAME exists"                   "vgs $VG_NAME"
t "3 logical volumes exist"                            "[ \$(lvs --noheadings $VG_NAME | wc -l) -ge 3 ]"
for m in $REPOS_MNT $PROJECTS_MNT $BACKUP_MNT; do
  t "$m is a mounted volume"                           "mountpoint -q $m"
  t "$m persistent in /etc/fstab"                      "grep -q ' $m ' /etc/fstab"
done
t "A backup archive exists"                            "ls $BACKUP_DIR/backup_*.tar.gz"
t "Latest backup checksum is valid"                    "cd $BACKUP_DIR && sha256sum -c \$(ls -1t backup_*.sha256 | head -1)"

echo "### Member 3 - Automation & security"
t "Cron job file installed"                            "[ -f /etc/cron.d/devserver ]"
t "Cron service active"                                "systemctl is-active --quiet $(svc_cron)"
t "Monitor log is being written"                       "[ -s $LOG_DIR/monitor.log ]"
t "Firewall active"                                    "ufw status | grep -q 'Status: active' || firewall-cmd --state"
t "Root SSH login disabled"                            "sshd -T | grep -qi 'permitrootlogin no'"
t "Backup dir not readable by others"                  "[ \$(stat -c %a $BACKUP_MNT) -le 750 ]"
t "Shared dir has setgid bit"                          "[ -g $PROJECTS_MNT ]"
t "Credential file is root-only (600)"                 "[ \$(stat -c %a $CRED_FILE) = 600 ]"
t "Developers have no unrestricted sudo"               "! sudo -l -U ${DEV_PREFIX}01 | grep -q '(ALL.*) ALL'"
t "Cleanup script runs (dry-run)"                      "bash $PROJECT_ROOT/member3_automation_security/01_cleanup.sh --dry-run"

if [[ "$DOCKER_ENABLE" == "yes" ]]; then
echo "### Docker (shared daemon)"
t "Docker engine installed"                              "command -v docker"
t "Docker service active"                                "systemctl is-active --quiet docker"
t "Docker data on its own LVM volume ($DOCKER_MNT)"      "mountpoint -q $DOCKER_MNT"
t "Docker volume persistent in /etc/fstab"               "grep -q ' $DOCKER_MNT ' /etc/fstab"
t "Docker Compose plugin available"                      "docker compose version"
t "Container log rotation configured"                    "grep -q max-size /etc/docker/daemon.json"
t "Published ports default to 127.0.0.1"                 "grep -q '127.0.0.1' /etc/docker/daemon.json"
t "${DEV_PREFIX}01 is in the $DOCKER_GROUP group"        "id -nG ${DEV_PREFIX}01 | grep -qw $DOCKER_GROUP"
t "${DEV_PREFIX}01 can use Docker without sudo"          "sudo -u ${DEV_PREFIX}01 docker info"
t "${DEV_PREFIX}02 reaches the same shared daemon"       "sudo -u ${DEV_PREFIX}02 docker ps"
fi
if [[ "$DOCKER_ENABLE" == "yes" && "$SWARM_ENABLE" == "yes" ]]; then
echo "### Orchestration (Docker Swarm)"
t "Swarm mode is active"                                 "[ \"\$(docker info --format '{{.Swarm.LocalNodeState}}')\" = active ]"
t "This server is a swarm manager"                       "docker node ls"
t "Swarm node(s) all Ready"                              "! docker node ls --format '{{.Status}}' | grep -qv Ready"
t "Overlay network $SWARM_NET exists"                    "docker network ls --filter driver=overlay --format '{{.Name}}' | grep -qx $SWARM_NET"
t "Stack folder exists with demo stack"                  "[ -f $STACKS_DIR/demo.yml ]"
t "Demo stack: all replicas running (2/2)"               "docker service ls --filter name=demo_web --format '{{.Replicas}}' | grep -qx '2/2'"
t "Demo service answers on port 9080 (swarm ingress)"    "curl -fsS --retry 4 --retry-delay 2 --retry-connrefused -o /dev/null --max-time 5 http://127.0.0.1:9080 || curl -fsS -o /dev/null --max-time 5 http://localhost:9080 || curl -fsS -o /dev/null --max-time 5 \"http://\$(hostname -I | awk '{print \$1}'):9080\" || wget -q -O /dev/null --timeout=5 http://127.0.0.1:9080 || wget -q -O /dev/null --timeout=5 http://localhost:9080"
t "${DEV_PREFIX}01 can list swarm services (no sudo)"    "sudo -u ${DEV_PREFIX}01 docker service ls"
[[ "$REGISTRY_ENABLE" == "yes" ]] && t "Private registry answers on localhost:5000"  "curl -fsS -o /dev/null --max-time 5 http://localhost:5000/v2/"
fi

echo "### Functional test"
t "Developer can write to shared project dir"          "sudo -u ${DEV_PREFIX}01 touch $PROJECTS_MNT/shared-tools/.t01 && sudo -u ${DEV_PREFIX}02 rm -f $PROJECTS_MNT/shared-tools/.t01"
t "Developer cannot read another developer's home"     "! sudo -u ${DEV_PREFIX}02 ls /home/${DEV_PREFIX}01"
t "Developer cannot access /backup"                    "! sudo -u ${DEV_PREFIX}01 ls $BACKUP_MNT"

echo; echo "RESULT: $PASS passed, $FAIL failed"
echo "SUMMARY - $PASS passed, $FAIL failed ($(date '+%F %T'))" >> "$REPORT"
log "Tests finished: $PASS pass / $FAIL fail"
[[ $FAIL -eq 0 ]]
