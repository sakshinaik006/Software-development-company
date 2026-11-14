# Viva Voce – Likely Questions & Short Answers

**Member 1 (Sysadmin)**
- *How did you create 40 users?* Loop in `02_users_groups.sh` using `useradd -m -g developers`, random password via `openssl rand`, `chage -d 0` forces change on first login.
- *Why primary group `developers`?* Shared access to repos/projects through group permissions.
- *Difference between `useradd` and `adduser`?* `useradd` is low-level/scriptable; `adduser` is an interactive Debian wrapper.
- *Why bare repositories?* A shared central repo has no working tree; developers push/pull. `--shared=group` keeps group write permission.

**Member 2 (Storage)**
- *Why LVM?* Resize volumes online, combine disks, snapshots. Demo: `04_extend_lvm_demo.sh`.
- *PV → VG → LV?* Physical volume (partition) → pool (volume group) → logical volume (what you format/mount).
- *Why ext4 and xfs?* ext4 for repos/projects (shrinkable); xfs for backups (large files, grow-only).
- *Why /etc/fstab and `nofail`?* Persistent mounts; server still boots if a volume is missing.
- *How do you verify a backup?* SHA-256 checksum, and a test restore with `06_restore.sh`.

**Member 3 (Automation & Security)**
- *Cron syntax?* `min hour dom month dow user command` – see `/etc/cron.d/devserver`.
- *What does setgid on a directory do?* New files inherit the directory's group (`chmod 2775`).
- *Firewall policy?* Default deny incoming; SSH (rate-limited) and dashboard port allowed.
- *Why disable root SSH login?* Prevents direct brute force against the most-targeted account.
- *What does fail2ban do?* Bans IPs after repeated failed logins.

**Member 4 (Testing & Docs)**
- *How did you test?* `01_run_tests.sh` – 35+ automated PASS/FAIL checks incl. functional tests (dev01 writes, dev02 cannot read dev01's home).
- *How is the dashboard built?* Python standard library HTTP server reading `/proc`, `df`, `lvs`, logs; JSON API at `/api/metrics`, page refreshes every 5 s.

**Docker (shared daemon)**
- *Why a dedicated LVM volume for Docker?* Images/layers grow fast; `lv_docker` stops them filling `/`, and can be grown online (`04_extend_lvm_demo.sh lv_docker +2G`).
- *What is the security risk of the `docker` group?* Anyone in it can start a container that mounts `/` - effectively root. Mitigations: trusted team only, `no-new-privileges`, optional `userns-remap`, audit via dashboard/owner labels.
- *Why do published ports bind to 127.0.0.1 by default?* Docker edits iptables directly and bypasses UFW, so an accidental `-p 80:80` would be open to the network. The default `ip` in `daemon.json` makes exposure an explicit choice.
- *What is the benefit of one shared daemon?* One image cache for all 40 developers (pull once), one place to monitor, clean and back up.
- *Are volumes cleaned automatically?* No. Weekly cleanup prunes only old stopped containers, unused images and build cache.
- *Why Swarm and not Kubernetes?* Swarm ships inside Docker (no extra install), uses the same Compose file format and is enough for one server that can grow to a few nodes. Kubernetes is the next step for large clusters.
- *What is a stack / service / task?* A stack is a group of services deployed from one YAML file; a service is the desired state (image, replicas, ports); a task is one running container of a service.
- *What does the manager do?* Holds the cluster state (Raft), schedules tasks, restarts failed containers and performs rolling updates. This server is the only manager now; workers can join with `docker swarm join`.
- *Why is `live-restore` not enabled?* Docker does not allow it together with swarm mode.
- *Which ports must be open between swarm nodes?* 2377/tcp (management), 7946/tcp+udp (gossip), 4789/udp (overlay VXLAN) - opened only for the IPs in `SWARM_PEERS`.
- *How do you update without downtime?* `update_config` with `order: start-first` / `docker service update`; `docker service rollback` undoes it.
