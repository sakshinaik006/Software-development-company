#!/usr/bin/env bash
# Runs the complete project in the correct order. Usage: sudo bash run_all.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config/common.sh"
require_root
R="$PROJECT_ROOT"
steps=(
  "member1_sysadmin/01_install_packages.sh"
  "member1_sysadmin/02_users_groups.sh"
  "member1_sysadmin/03_services_network.sh"
  "member2_storage_backup/01_partition_disks.sh"
  "member2_storage_backup/02_lvm_setup.sh"
  "member2_storage_backup/03_filesystems_mount.sh"
  "member1_sysadmin/04_shared_repos.sh"
  "member1_sysadmin/05_docker.sh"
  "member1_sysadmin/06_swarm.sh"
  "member3_automation_security/04_permissions_access.sh"
  "member3_automation_security/05_security_hardening.sh"
  "member3_automation_security/03_firewall.sh"
  "member2_storage_backup/05_backup.sh"
  "member3_automation_security/02_cron_setup.sh"
  "member3_automation_security/06_monitor.sh"
  "member2_storage_backup/07_validate_storage.sh"
  "member4_testing_docs/03_install_dashboard.sh"
  "member4_testing_docs/01_run_tests.sh"
  "member4_testing_docs/02_generate_report.sh"
)
for s in "${steps[@]}"; do
  echo; echo "=================== $s ==================="
  bash "$R/$s" || warn "step returned non-zero: $s (continuing)"
done
echo; ok "ALL DONE. Dashboard: http://$(hostname -I | awk '{print $1}'):$DASH_PORT"
echo "Developer passwords: $CRED_FILE"
[[ "$DOCKER_ENABLE" == "yes" ]] && echo "Developers: log out/in once, then try:  docker run --rm hello-world   |   cat $STACKS_DIR/README.txt"
