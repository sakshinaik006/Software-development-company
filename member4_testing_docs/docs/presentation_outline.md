# Presentation Outline (10–12 slides, ~10 min)
1. Title & team roles
2. Problem statement & objectives
3. Architecture diagram (disks → LVM → mounts → Docker → Swarm)
4. Member 1 – users, packages, services, network (demo: `id dev01`, `getent group developers`)
5. Member 2 – partitioning, LVM, live extend (demo: `04_extend_lvm_demo.sh`)
6. Member 2 – backup & restore (demo: `05_backup.sh`, `06_restore.sh`)
7. Member 3 – cron, cleanup, monitoring (demo: `01_cleanup.sh --dry-run`, `cat /etc/cron.d/devserver`)
8. Member 3 – security: firewall, SSH hardening, permissions
9. Docker & orchestration (demo: `docker stack ls`, `docker service scale demo_web=4`, `docker service ls`, open http://SERVER_IP:9080)
9b. Member 4 – testing (demo: `01_run_tests.sh`)
10. Live dashboard demo (open http://SERVER_IP:8080; trigger an alert by running `yes > /dev/null &`)
11. Challenges & lessons learned
12. Conclusion, future scope, Q&A
