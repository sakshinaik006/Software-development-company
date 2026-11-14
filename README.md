# Container & Orchestration Server for a Software Development Company (40 developers)

**Main application: Docker** - one shared container engine with **Docker Swarm** orchestration (stacks, scaling, rolling updates, overlay network, private registry).
Around it: users, shared Git repositories, LVM storage, backup, cron automation, security and a web dashboard - organised by team member.

```
linux-dev-server/
├── run_all.sh                       <- runs everything in the right order
├── config/  project.conf, common.sh <- ALL settings (users, sizes, mounts, thresholds)
├── member1_sysadmin/                01 packages · 02 users/groups · 03 services+network · 04 shared repos · 05 DOCKER · 06 SWARM · 99 rollback
├── member2_storage_backup/          01 partition · 02 LVM · 03 filesystems/fstab · 04 extend LV · 05 backup · 06 restore · 07 validate · 08 cloud sync
├── member3_automation_security/     01 cleanup · 02 cron · 03 firewall · 04 permissions · 05 hardening · 06 monitor · 07 troubleshoot
└── member4_testing_docs/            01 tests · 02 report · 03 install dashboard · 04 run dashboard
    ├── dashboard/server.py          <- web dashboard (Python stdlib only)
    └── docs/                        documentation template, viva Q&A, presentation outline
```

## Requirements
* Ubuntu / Debian (or RHEL/Rocky/Alma) **virtual machine** with root/sudo, internet, ~12 GB free disk (the 2 virtual disks are sparse), **2+ vCPU and 4 GB RAM recommended** for containers.
* Do **not** run on your personal laptop – it creates 40 users, firewall rules, etc.  Use a VM (VirtualBox / VMware / WSL not recommended – needs systemd + LVM).

## Quick start (everything)
```bash
unzip linux-dev-server.zip && cd linux-dev-server
sudo bash run_all.sh
```
Then open the dashboard: **http://SERVER-IP:8080** (find the IP with `hostname -I`).
Developer temporary passwords: `sudo cat /root/dev_credentials.txt`.

## Storage mode
Default `LAB_MODE="loop"` creates two 5 GB *sparse image files* used as virtual disks, so it works on any VM with no extra hardware.
If you added real spare disks in your VM (e.g. `/dev/sdb`, `/dev/sdc`), edit `config/project.conf`:
```
LAB_MODE="disk"
DISKS="/dev/sdb /dev/sdc"
```
(`lsblk` first – the chosen disks are wiped!)

## Run step by step (each member runs their own part)
| Order | Member | Command |
|---|---|---|
| 1 | M1 | `sudo bash member1_sysadmin/01_install_packages.sh` |
| 2 | M1 | `sudo bash member1_sysadmin/02_users_groups.sh` |
| 3 | M1 | `sudo bash member1_sysadmin/03_services_network.sh` |
| 4 | M2 | `sudo bash member2_storage_backup/01_partition_disks.sh` |
| 5 | M2 | `sudo bash member2_storage_backup/02_lvm_setup.sh` |
| 6 | M2 | `sudo bash member2_storage_backup/03_filesystems_mount.sh` |
| 7 | M1 | `sudo bash member1_sysadmin/04_shared_repos.sh` |
| 8 | M3 | `sudo bash member3_automation_security/04_permissions_access.sh` |
| 9 | M3 | `sudo bash member3_automation_security/05_security_hardening.sh` |
| 10 | M3 | `sudo bash member3_automation_security/03_firewall.sh` |
| 11 | M1 | `sudo bash member1_sysadmin/05_docker.sh` |
| 12 | M1 | `sudo bash member1_sysadmin/06_swarm.sh` |
| 13 | M2 | `sudo bash member2_storage_backup/05_backup.sh` |
| 14 | M3 | `sudo bash member3_automation_security/02_cron_setup.sh` |
| 15 | M3 | `sudo bash member3_automation_security/06_monitor.sh` |
| 16 | M2 | `sudo bash member2_storage_backup/07_validate_storage.sh` |
| 17 | M4 | `sudo bash member4_testing_docs/03_install_dashboard.sh` |
| 18 | M4 | `sudo bash member4_testing_docs/01_run_tests.sh` and `02_generate_report.sh` |

The firewall runs **before** Docker on purpose: Docker adds its own network rules when it starts. If you re-run `03_firewall.sh` later, run `sudo systemctl restart docker` afterwards (containers restart).

## Containers & orchestration (Docker + Swarm)
Controlled by `DOCKER_ENABLE`, `SWARM_ENABLE` ... in `config/project.conf`.
* **One shared daemon** for `dev01`..`dev40` (group `docker`, no sudo): one image cache, one place to monitor, clean and back up. Rules: `/srv/projects/shared-tools/docker/README.txt`.
* **Storage:** own LVM volume `lv_docker` on `/var/lib/docker` (6 GB; grow online: `sudo bash member2_storage_backup/04_extend_lvm_demo.sh lv_docker +2G`).
* **Orchestration:** this server is the Swarm **manager** (`06_swarm.sh`): overlay network `devnet`, private registry `localhost:5000`, shared folder `/srv/projects/shared-tools/stacks` (workflow + rules in its `README.txt`, example `demo.yml`: nginx x2 replicas on port 9080).
* **Developer workflow:** `docker build` -> `docker push localhost:5000/dev01/app` -> `docker stack deploy -c app.yml dev01-app` -> `docker service scale ...` / `docker service update` / `docker service rollback`.
* **Add worker nodes** (e.g. cloud VMs): put their IPs in `SWARM_PEERS`, re-run `03_firewall.sh`, then `docker swarm join-token worker` on this server and run the printed command on the worker. For workers the registry must be exposed with TLS + auth (not configured here).
* **Daemon hardening** (`/etc/docker/daemon.json`): log rotation, `no-new-privileges`, plain-container ports bind to `127.0.0.1`; `live-restore` is left out because Docker forbids it with swarm; optional `DOCKER_USERNS="yes"`.
* **Operations:** weekly cleanup prunes old stopped containers/unused images/build cache (never volumes); `/var/lib/docker/volumes` and `/var/lib/docker/swarm` are in the nightly backup; the monitor logs `containers=N` and alerts when the daemon is down, a service has missing replicas or a node is not Ready; the dashboard shows Docker and Swarm panels.
* **Security warnings:** the `docker` group is **root-equivalent** (and on a manager it controls the whole cluster) - trusted developers only. Docker/Swarm publish ports through iptables and **bypass UFW**: swarm ports listen on all interfaces, so the 9000-9999 range is a convention, not enforced.
* **Backup caveat:** `/var/lib/docker/swarm` is copied while Docker runs (best effort). Keep stack files in Git; for a guaranteed cluster-state backup stop Docker briefly and copy that folder.
* Turn it all off with `DOCKER_ENABLE="no"`; keep Docker but skip clustering with `SWARM_ENABLE="no"`.

## Dashboard
* **As a service (permanent):** `sudo bash member4_testing_docs/03_install_dashboard.sh`
  Manage: `sudo systemctl status|restart|stop devserver-dashboard`
* **Foreground for a demo:** `sudo bash member4_testing_docs/04_run_dashboard.sh` → `http://localhost:8080`
* **Password-protect:** `sudo DASH_USER=admin DASH_PASS=secret python3 member4_testing_docs/dashboard/server.py`
* **Change port:** set `DASH_PORT` in `config/project.conf`, then rerun `03_firewall.sh` and `03_install_dashboard.sh`.
* Shows: CPU, memory, load, developers & sessions, failed SSH logins, mounted volumes, LVM layout, service status, backups, cron schedule, alerts, test results, top processes. JSON API: `/api/metrics`.
* Run it as root, otherwise LVM / firewall / log data will be empty. It also runs without root (or on any Linux box) for a quick look.

## Useful demo commands
```bash
sudo bash member3_automation_security/01_cleanup.sh --dry-run     # cleanup preview
sudo bash member2_storage_backup/04_extend_lvm_demo.sh            # grow lv_repos online
sudo bash member2_storage_backup/05_backup.sh                     # run a backup now
sudo bash member2_storage_backup/06_restore.sh                    # test restore to /tmp/restore_test
sudo bash member3_automation_security/07_troubleshoot.sh --fix    # diagnose + auto-fix
tail -f /var/log/devserver/monitor.log                            # live monitoring log
git clone ssh://dev01@localhost/srv/repos/project-alpha.git       # developer using a repo
sudo docker service ls ; sudo docker node ls                       # swarm overview
sudo docker service scale demo_web=4                              # scale the demo stack, then open http://SERVER-IP:9080
sudo docker stack rm demo                                          # remove the demo stack
```

## Undo / start over
`sudo bash member1_sysadmin/99_remove_users.sh` removes users. To remove storage:
```bash
sudo umount /srv/repos /srv/projects /backup
sudo lvremove -y vg_devserver; sudo vgremove vg_devserver
sudo losetup -D; sudo rm -rf /var/lab-disks
# and delete the three lines in /etc/fstab
```

## Troubleshooting
| Problem | Fix |
|---|---|
| `Run as root` | prefix with `sudo` |
| Mounts missing after reboot (loop mode) | `sudo systemctl start lab-loopdisks && sudo mount -a` or `07_troubleshoot.sh --fix` |
| Can't open dashboard from another PC | VM network must be *Bridged*; check `sudo ufw status` shows 8080 |
| `parted`/`lvm` not found | rerun `01_install_packages.sh` |
| Firewall locked you out | use the VM console: `sudo ufw disable` |
| `swarm init failed` | `live-restore` in `/etc/docker/daemon.json` - re-run `05_docker.sh`, then `06_swarm.sh` |
| Demo stack stays `0/2` | images need internet: `docker service ps demo_web --no-trunc` |
| Container networking broken after re-running the firewall | `sudo systemctl restart docker` |
| `permission denied` on docker.sock | developer must log out and in once (new `docker` group) |
