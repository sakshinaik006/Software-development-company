# Project Documentation – Container & Orchestration Server (Docker + Swarm) for a Software Development Company

## 1. Problem statement
Linux server for 40 developers whose main application is **Docker**: one shared container engine with Swarm orchestration (stacks, scaling, rolling updates, overlay network, private registry), plus accounts, shared repositories, storage management, backup, automation, security and monitoring.

## 2. Team and responsibilities
| Member | Role | Folder |
|---|---|---|
| 1 | Linux System Administrator (Leader) | member1_sysadmin |
| 2 | Storage & Backup Administrator | member2_storage_backup |
| 3 | Automation & Security Engineer | member3_automation_security |
| 4 | Testing, Documentation & Presentation | member4_testing_docs |

## 3. Architecture
(Insert diagram: 2 disks → GPT partitions → PV → VG `vg_devserver` → LVs `lv_repos`, `lv_projects`, `lv_backup`, `lv_docker` → mounted at /srv/repos, /srv/projects, /backup, /var/lib/docker; Docker daemon → Swarm manager → overlay network `devnet` → stacks/services.)

## 4. Implementation steps (attach screenshots from `system_report.md`)
1. Packages – `01_install_packages.sh`
2. Users & groups – `02_users_groups.sh`
3. Services & network – `03_services_network.sh`
4. Partitioning / LVM / filesystems – member2 scripts 01–03
5. Shared repositories – `04_shared_repos.sh`
6. Permissions, hardening, firewall – member3 scripts 03–05
7. Cron automation, cleanup, backup, monitoring
8. Docker engine – `05_docker.sh`; Swarm orchestration, registry, demo stack – `06_swarm.sh`
9. Dashboard (containers + swarm panels) – `server.py`

## 5. Test results
Paste `/var/log/devserver/test_report.txt`.

## 6. Problems faced and solutions
| Problem | Cause | Solution |
|---|---|---|

## 7. Conclusion & future scope
Additional swarm worker nodes in the cloud, TLS + authentication for the registry, Traefik/Nginx reverse proxy with HTTPS, rootless Docker, LDAP central authentication, disk quotas, Prometheus/Grafana, off-site backups.
