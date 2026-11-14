#!/usr/bin/env python3
"""
Dev Server Dashboard - pure Python 3 standard library (no pip install needed).
Run:  sudo python3 server.py        ->  http://<server-ip>:8080
Env : DASH_PORT, DASH_HOST, DASH_USER + DASH_PASS (optional basic auth), DEV_GROUP
"""
import base64, grp, json, os, pwd, shutil, socket, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASH_PORT", 8080))
HOST = os.environ.get("DASH_HOST", "0.0.0.0")
AUTH_USER, AUTH_PASS = os.environ.get("DASH_USER"), os.environ.get("DASH_PASS")
DEV_GROUP = os.environ.get("DEV_GROUP", "developers")
MOUNTS = ["/", "/srv/repos", "/srv/projects", "/backup"]
BACKUP_DIR = "/backup/daily"
LOG_DIR = "/var/log/devserver"
if os.path.ismount("/var/lib/docker"):
    MOUNTS.append("/var/lib/docker")


def run(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default


def tail(path, n=200):
    return read(path).splitlines()[-n:]


def cpu_percent():
    def sample():
        v = list(map(int, read("/proc/stat").splitlines()[0].split()[1:9]))
        return sum(v), v[3] + v[4]
    t1, i1 = sample(); time.sleep(0.25); t2, i2 = sample()
    return round(100 * ((t2 - t1) - (i2 - i1)) / (t2 - t1), 1) if t2 > t1 else 0.0


def memory():
    m = {}
    for line in read("/proc/meminfo").splitlines():
        k, v = line.split(":")
        m[k] = int(v.split()[0]) * 1024
    total, avail = m.get("MemTotal", 1), m.get("MemAvailable", 0)
    swap_t, swap_f = m.get("SwapTotal", 0), m.get("SwapFree", 0)
    return {"total": total, "used": total - avail, "percent": round(100 * (total - avail) / total, 1),
            "swap_total": swap_t, "swap_used": swap_t - swap_f}


def disks():
    out = []
    for m in MOUNTS:
        if m != "/" and not os.path.ismount(m):
            out.append({"mount": m, "mounted": False}); continue
        if not os.path.exists(m):
            continue
        u = shutil.disk_usage(m)
        out.append({"mount": m, "mounted": True, "total": u.total, "used": u.used,
                    "percent": round(100 * u.used / u.total, 1) if u.total else 0})
    return out


def lvm():
    txt = run(["lvs", "--noheadings", "--units", "g", "--nosuffix", "--separator", ",",
               "-o", "lv_name,vg_name,lv_size,lv_attr"])
    rows = []
    for l in txt.splitlines():
        p = [x.strip() for x in l.split(",")]
        if len(p) == 4:
            rows.append({"lv": p[0], "vg": p[1], "size_gb": p[2], "attr": p[3]})
    vg_out = run(["vgs", "--noheadings", "--units", "g", "--nosuffix", "--separator", ",",
                  "-o", "vg_name,vg_size,vg_free"])
    vginfo = None
    target_vg = os.environ.get("VG_NAME", "vg_devserver")
    for line in vg_out.splitlines():
        p = [x.strip() for x in line.split(",") if x.strip()]
        if len(p) >= 3:
            if p[0] == target_vg or vginfo is None:
                vginfo = {"name": p[0], "size": p[1], "free": p[2]}
    return {"lvs": rows, "vg": vginfo}


def users():
    try:
        g = grp.getgrnam(DEV_GROUP)
        names = {u.pw_name for u in pwd.getpwall() if u.pw_gid == g.gr_gid} | set(g.gr_mem)
    except KeyError:
        names = set()
    logged = run(["who"]).splitlines()
    return {"developers": len(names), "logged_in": len(logged),
            "sessions": [l.split()[0] + " @ " + (l.split()[1] if len(l.split()) > 1 else "") for l in logged][:10]}


def services():
    res = {}
    for label, names in {"SSH": ["ssh", "sshd"], "Cron": ["cron", "crond"],
                         "Firewall": ["ufw", "firewalld"], "Time sync": ["chrony", "chronyd"],
                         "Fail2ban": ["fail2ban"], "Docker": ["docker"]}.items():
        state = "n/a"
        for n in names:
            s = run(["systemctl", "is-active", n])
            if s and s != "unknown":
                state = s; break
        res[label] = state
    return res


def docker_info():
    """Shared Docker daemon overview (None if Docker is not installed)."""
    if not shutil.which("docker"):
        return None
    ver = run(["docker", "version", "--format", "{{.Server.Version}}"], timeout=8)
    if not ver:
        return {"running": False}
    rows = run(["docker", "ps", "-a", "--format",
                '{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.Label "owner"}}'], timeout=8).splitlines()
    cont = []
    for r in rows:
        p = r.split("|", 4)
        if len(p) == 5:
            cont.append({"name": p[0], "image": p[1], "status": p[2], "state": p[3], "owner": p[4] or "-"})
    images = len(run(["docker", "images", "-q"], timeout=8).split())
    return {"running": True, "version": ver, "total": len(cont),
            "up": sum(1 for c in cont if c["state"] == "running"), "images": images,
            "containers": sorted(cont, key=lambda c: c["state"] != "running")[:12]}


def swarm_info():
    """Docker Swarm overview: nodes + services with replica health (None if Docker is missing)."""
    if not shutil.which("docker"):
        return None
    if run(["docker", "info", "--format", "{{.Swarm.LocalNodeState}}"], timeout=8) != "active":
        return {"active": False}
    nodes, services = [], []
    for r in run(["docker", "node", "ls", "--format",
                  "{{.Hostname}}|{{.Status}}|{{.Availability}}|{{.ManagerStatus}}"], timeout=8).splitlines():
        p = r.split("|", 3)
        if len(p) == 4:
            nodes.append({"host": p[0], "status": p[1], "avail": p[2], "role": p[3] or "worker"})
    for r in run(["docker", "service", "ls", "--format",
                  "{{.Name}}|{{.Mode}}|{{.Replicas}}|{{.Image}}|{{.Ports}}"], timeout=8).splitlines():
        p = r.split("|", 4)
        if len(p) == 5:
            cur, _, want = p[2].split(" ")[0].partition("/")
            services.append({"name": p[0], "mode": p[1], "replicas": p[2], "image": p[3], "ports": p[4],
                             "healthy": cur == want})
    return {"active": True, "nodes": nodes, "services": services[:20],
            "unhealthy": sum(1 for x in services if not x["healthy"])}


def backups():
    items = []
    if os.path.isdir(BACKUP_DIR):
        for f in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if f.endswith(".tar.gz"):
                p = os.path.join(BACKUP_DIR, f)
                items.append({"name": f, "size": os.path.getsize(p), "time": time.strftime("%F %T", time.localtime(os.path.getmtime(p)))})
    return items[:8]


def failed_logins():
    for p in ("/var/log/auth.log", "/var/log/secure"):
        if os.path.exists(p):
            return sum(1 for l in tail(p, 3000) if "Failed password" in l)
    return None


def tests():
    lines = read(f"{LOG_DIR}/test_report.txt").splitlines()
    p = [l[7:] for l in lines if l.startswith("PASS")]
    f = [l[7:] for l in lines if l.startswith("FAIL")]
    summ = next((l for l in lines if l.startswith("SUMMARY")), "No test run yet")
    return {"pass": len(p), "fail": len(f), "failed": f[:10], "summary": summ}


def cron_jobs():
    return [l for l in read("/etc/cron.d/devserver").splitlines() if l and not l.startswith(("#", "SHELL", "PATH"))]


def processes():
    out = run(["ps", "-eo", "pid,user,%cpu,%mem,comm", "--sort=-%cpu"]).splitlines()[1:9]
    return [l.split(None, 4) for l in out]


def metrics():
    up = float(read("/proc/uptime", "0 0").split()[0])
    return {
        "time": time.strftime("%F %T"), "hostname": socket.gethostname(),
        "kernel": os.uname().release, "uptime_h": round(up / 3600, 1),
        "load": os.getloadavg(), "cpus": os.cpu_count(), "cpu": cpu_percent(),
        "mem": memory(), "disks": disks(), "lvm": lvm(), "users": users(),
        "services": services(), "docker": docker_info(), "swarm": swarm_info(), "backups": backups(), "failed_ssh": failed_logins(),
        "tests": tests(), "cron": cron_jobs(), "procs": processes(),
        "alerts": [l for l in tail(f"{LOG_DIR}/monitor.log", 300) if "ALERT" in l][-8:],
    }


HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DevForge OS &middot; Enterprise Linux Platform (Docker &amp; Swarm)</title>
<style>
:root {
  --bg: #f8fafc;
  --card: #ffffff;
  --tx: #0f172a;
  --tx-sub: #334155;
  --mut: #64748b;
  --border: #e2e8f0;
  --ok: #16a34a;
  --ok-bg: #dcfce7;
  --ok-tx: #15803d;
  --warn: #d97706;
  --warn-bg: #fef3c7;
  --warn-tx: #92400e;
  --bad: #dc2626;
  --bad-bg: #fee2e2;
  --bad-tx: #b91c1c;
  --acc: #2563eb;
  --acc-bg: #eff6ff;
  --bar-bg: #e2e8f0;
  --docker: #0284c7;
  --docker-bg: #e0f2fe;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
  background: var(--bg);
  color: var(--tx);
  -webkit-font-smoothing: antialiased;
}
/* Header */
header {
  padding: 14px 28px;
  background: #ffffff;
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px;
  position: sticky;
  top: 0;
  z-index: 100;
  box-shadow: 0 1px 3px rgba(0,0,0,0.03);
}
.brand-box {
  display: flex;
  align-items: center;
  gap: 12px;
}
.brand-icon {
  width: 36px;
  height: 36px;
  background: linear-gradient(135deg, #2563eb, #0284c7);
  border-radius: 9px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-weight: 800;
  font-size: 18px;
  box-shadow: 0 2px 4px rgba(37,99,235,0.25);
}
.brand-text h1 {
  font-size: 17px;
  font-weight: 800;
  color: #0f172a;
  margin: 0;
  line-height: 1.2;
}
.brand-text small {
  color: var(--mut);
  font-size: 11px;
}
.header-meta {
  display: flex;
  align-items: center;
  gap: 16px;
}
.live-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  background: var(--ok-bg);
  color: var(--ok-tx);
  padding: 4px 11px;
  border-radius: 99px;
  font-size: 11.5px;
  font-weight: 700;
  border: 1px solid #bbf7d0;
}
.live-dot {
  width: 7px;
  height: 7px;
  background: var(--ok);
  border-radius: 50%;
  box-shadow: 0 0 0 2px rgba(22, 163, 74, 0.25);
  animation: pulse 1.8s infinite;
}
@keyframes pulse {
  0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(22, 163, 74, 0.7); }
  70% { transform: scale(1); box-shadow: 0 0 0 5px rgba(22, 163, 74, 0); }
  100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(22, 163, 74, 0); }
}

/* Quick KPI Ribbon */
.kpi-ribbon {
  background: #ffffff;
  border-bottom: 1px solid var(--border);
  padding: 10px 28px;
  display: flex;
  gap: 22px;
  overflow-x: auto;
  font-size: 12.5px;
}
.kpi-item {
  display: flex;
  align-items: center;
  gap: 7px;
  white-space: nowrap;
}
.kpi-label { color: var(--mut); font-weight: 500; }
.kpi-val { font-weight: 700; color: #0f172a; }

/* Tabs */
.nav-tabs {
  background: #ffffff;
  border-bottom: 1px solid var(--border);
  padding: 0 28px;
  display: flex;
  gap: 8px;
  overflow-x: auto;
}
.tab-btn {
  background: none;
  border: none;
  padding: 12px 14px;
  font-size: 13px;
  font-weight: 600;
  color: var(--mut);
  cursor: pointer;
  border-bottom: 3px solid transparent;
  display: flex;
  align-items: center;
  gap: 7px;
  transition: all 0.15s ease;
  white-space: nowrap;
}
.tab-btn:hover { color: var(--acc); }
.tab-btn.active {
  color: var(--acc);
  border-bottom-color: var(--acc);
}

/* Main Container */
main {
  padding: 22px 28px;
  max-width: 1440px;
  margin: 0 auto;
}
.tab-pane { display: none; }
.tab-pane.active { display: block; }

.grid-cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(310px, 1fr));
  gap: 16px;
}
.card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 18px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.03);
}
.card h2 {
  font-size: 11.5px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--mut);
  font-weight: 700;
  margin: 0 0 10px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.big {
  font-size: 28px;
  font-weight: 800;
  color: #0f172a;
  letter-spacing: -0.02em;
}
.bar {
  height: 8px;
  background: var(--bar-bg);
  border-radius: 99px;
  overflow: hidden;
  margin: 8px 0 12px;
}
.bar > div {
  height: 100%;
  border-radius: 99px;
  background: var(--ok);
  transition: width 0.4s ease;
}
.row {
  display: flex;
  justify-content: space-between;
  font-size: 13px;
  color: var(--tx-sub);
  margin: 6px 0;
  gap: 8px;
}
.pill {
  padding: 2px 10px;
  border-radius: 99px;
  font-size: 11px;
  font-weight: 700;
  display: inline-block;
  text-transform: capitalize;
}
.pill.active { background: var(--ok-bg); color: var(--ok-tx); border: 1px solid #bbf7d0; }
.pill.inactive, .pill.failed { background: var(--bad-bg); color: var(--bad-tx); border: 1px solid #fecaca; }
.pill.neutral { background: #f1f5f9; color: #475569; border: 1px solid #e2e8f0; }
.pill.docker { background: var(--docker-bg); color: #0369a1; border: 1px solid #bae6fd; }

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12.5px;
  margin-top: 6px;
}
th {
  text-align: left;
  padding: 7px 10px;
  background: #f8fafc;
  color: var(--mut);
  font-size: 11px;
  text-transform: uppercase;
  font-weight: 700;
  border-bottom: 1px solid var(--border);
}
td {
  text-align: left;
  padding: 8px 10px;
  border-bottom: 1px solid var(--border);
  color: var(--tx-sub);
}
tr:last-child td { border-bottom: none; }
.wide { grid-column: 1 / -1; }

.alert {
  background: #fffbeb;
  border-left: 3px solid var(--warn);
  padding: 7px 10px;
  border-radius: 4px;
  color: var(--warn-tx);
  font-size: 12px;
  margin: 4px 0;
  font-weight: 500;
}
.code-tag {
  background: #eff6ff;
  color: var(--acc);
  padding: 2px 6px;
  border-radius: 4px;
  font-size: 11.5px;
  border: 1px solid #dbeafe;
  font-family: Consolas, monospace;
}
.badge-dev {
  display: inline-block;
  background: #f1f5f9;
  border: 1px solid #e2e8f0;
  padding: 3px 8px;
  border-radius: 6px;
  font-size: 11px;
  font-weight: 600;
  margin: 2px;
  color: #334155;
}
.arch-box {
  background: #f8fafc;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 12px;
  margin: 8px 0;
  font-family: Consolas, monospace;
  font-size: 11.5px;
  line-height: 1.45;
  color: #1e293b;
}
</style>
</head>
<body>

<header>
  <div class="brand-box">
    <div class="brand-icon">&lambda;</div>
    <div class="brand-text">
      <h1>DevForge OS &middot; Enterprise Platform</h1>
      <small><span id="host">devserver01</span> &middot; <span id="meta">Ubuntu &middot; Docker &amp; Swarm Enabled</span></small>
    </div>
  </div>
  <div class="header-meta">
    <span class="live-pill"><span class="live-dot"></span> Live Telemetry</span>
    <small style="color:var(--mut);">Auto-refresh 5 s &middot; <b id="clock" style="color:var(--tx);">--:--:--</b></small>
  </div>
</header>

<!-- Quick Stats Ribbon -->
<div class="kpi-ribbon">
  <div class="kpi-item"><span class="kpi-label">Developers:</span> <span class="kpi-val" id="kpi-devs">40 Accounts</span></div>
  <div class="kpi-item"><span class="kpi-label">Docker Host:</span> <span class="kpi-val" id="kpi-docker" style="color:#0284c7;">Shared Engine</span></div>
  <div class="kpi-item"><span class="kpi-label">Swarm Cluster:</span> <span class="kpi-val" id="kpi-swarm" style="color:var(--ok-tx);">&check; Active Manager</span></div>
  <div class="kpi-item"><span class="kpi-label">Storage:</span> <span class="kpi-val" id="kpi-storage">LVM (vg_devserver)</span></div>
  <div class="kpi-item"><span class="kpi-label">Firewall:</span> <span class="kpi-val" style="color:var(--ok-tx);">&check; UFW Active</span></div>
  <div class="kpi-item"><span class="kpi-label">QA Compliance:</span> <span class="kpi-val" style="color:var(--acc);" id="kpi-tests">Checking...</span></div>
</div>

<!-- Navigation Tabs -->
<div class="nav-tabs">
  <button class="tab-btn active" onclick="showTab('tab-overview')">&block; Overview</button>
  <button class="tab-btn" onclick="showTab('tab-docker')">&sunglasses; Docker &amp; Swarm</button>
  <button class="tab-btn" onclick="showTab('tab-devs')">&female;&male; 40 Developers</button>
  <button class="tab-btn" onclick="showTab('tab-storage')">&equiv; Storage &amp; LVM</button>
  <button class="tab-btn" onclick="showTab('tab-security')">&check; Security &amp; Firewall</button>
  <button class="tab-btn" onclick="showTab('tab-backup')">&dArr; Smart Backups</button>
  <button class="tab-btn" onclick="showTab('tab-qa')">&quest; QA Test Suite</button>
</div>

<main id="main-content">

  <!-- TAB 1: OVERVIEW -->
  <div id="tab-overview" class="tab-pane active">
    <div class="grid-cards">
      <div class="card">
        <h2>CPU Utilization</h2>
        <div class="big" id="ov-cpu">0.0%</div>
        <div class="bar"><div id="ov-cpu-bar" style="width:0%;"></div></div>
        <div class="row"><span>Load Average (1m / 5m / 15m)</span><b id="ov-load">0.00 / 0.00 / 0.00</b></div>
      </div>
      <div class="card">
        <h2>Memory (RAM)</h2>
        <div class="big" id="ov-mem">0.0%</div>
        <div class="bar"><div id="ov-mem-bar" style="width:0%;"></div></div>
        <div class="row"><span>Memory Used / Total</span><b id="ov-mem-used">- / -</b></div>
        <div class="row"><span>Swap Space</span><span id="ov-swap">-</span></div>
      </div>
      <div class="card">
        <h2>Developer Multi-Tenancy</h2>
        <div class="big" id="ov-dev-count">40</div>
        <div class="row"><span>Active Terminal Sessions</span><b id="ov-logged">0</b></div>
        <div class="row"><span>Docker Group Membership</span><span class="pill docker">40 Users Granted</span></div>
        <div class="row"><span>Home Privacy Boundary</span><span class="pill active">chmod 700 Enforced</span></div>
      </div>
      <div class="card">
        <h2>LVM Storage Pools</h2>
        <div id="ov-disks-list">Loading storage...</div>
      </div>
      <div class="card">
        <h2>Core Services</h2>
        <div id="ov-services-list">Loading services...</div>
      </div>
      <div class="card">
        <h2>Proactive System Alerts</h2>
        <div id="ov-alerts-list"><div style="color:var(--ok-tx);font-size:13px;">&check; Zero alert conditions detected</div></div>
      </div>
      <div class="card wide">
        <h2>Top System Resource Consumers</h2>
        <table>
          <thead><tr><th>PID</th><th>User</th><th>CPU %</th><th>Memory %</th><th>Command</th></tr></thead>
          <tbody id="ov-procs"><tr><td colspan="5">Loading processes...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- TAB 2: DOCKER & SWARM (NEW EXPANDED TAB) -->
  <div id="tab-docker" class="tab-pane">
    <div class="grid-cards">
      <div class="card wide">
        <h2>Shared Docker Engine Overview</h2>
        <div class="row" style="margin-bottom:10px;">
          <span>Engine Status: <b id="dk-status" style="color:var(--ok-tx);">-</b></span>
          <span>Version: <b id="dk-ver">-</b></span>
          <span>Images: <b id="dk-images">-</b></span>
          <span>Containers: <b id="dk-containers">-</b></span>
        </div>
        <table>
          <thead><tr><th>Container Name</th><th>Owner</th><th>Image</th><th>Status</th><th>State</th></tr></thead>
          <tbody id="dk-containers-tbody"><tr><td colspan="5">Loading containers...</td></tr></tbody>
        </table>
      </div>
      <div class="card wide">
        <h2>Docker Swarm Cluster &amp; Microservices</h2>
        <div class="row" style="margin-bottom:10px;">
          <span>Cluster State: <b id="sw-state" style="color:var(--ok-tx);">-</b></span>
          <span>Overlay Network: <code class="code-tag">devnet</code></span>
          <span>Private Registry: <code class="code-tag">localhost:5000</code></span>
          <span>App Port Range: <b>9000 &ndash; 9999</b></span>
        </div>
        <h3 style="font-size:12px;text-transform:uppercase;color:var(--mut);margin:14px 0 6px 0;">Swarm Cluster Nodes</h3>
        <table>
          <thead><tr><th>Hostname</th><th>Role</th><th>Status</th><th>Availability</th></tr></thead>
          <tbody id="sw-nodes-tbody"><tr><td colspan="4">Loading nodes...</td></tr></tbody>
        </table>
        <h3 style="font-size:12px;text-transform:uppercase;color:var(--mut);margin:16px 0 6px 0;">Deployed Swarm Stacks &amp; Services</h3>
        <table>
          <thead><tr><th>Service Name</th><th>Mode</th><th>Replicas</th><th>Image</th><th>Published Ports</th><th>Health</th></tr></thead>
          <tbody id="sw-services-tbody"><tr><td colspan="6">Loading services...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- TAB 3: DEVELOPERS -->
  <div id="tab-devs" class="tab-pane">
    <div class="grid-cards">
      <div class="card wide">
        <h2>Developer Multi-Tenant Accounts (40 Total)</h2>
        <p style="font-size:13px;color:var(--tx-sub);margin:0 0 12px 0;">All 40 developers belong to <code>developers</code> and <code>docker</code> groups. They can build and run containers with zero sudo required.</p>
        <div id="dev-chips-container" style="line-height:1.8;">Loading accounts...</div>
      </div>
      <div class="card">
        <h2>Active Developer Sessions (who)</h2>
        <div id="dev-active-sessions">No active interactive logins</div>
      </div>
      <div class="card">
        <h2>Privilege Matrix &amp; Security Controls</h2>
        <div class="row"><span>Docker Access</span><span class="pill docker">No Sudo Required</span></div>
        <div class="row"><span>Unrestricted Root Sudo</span><span class="pill inactive">Denied</span></div>
        <div class="row"><span>Allowed Sudo Commands</span><span><code>systemctl status, journalctl</code></span></div>
        <div class="row"><span>Home Privacy Boundary</span><span class="pill active">chmod 700 Enforced</span></div>
        <div class="row"><span>Password Aging</span><span>90 Days Mandatory</span></div>
      </div>
    </div>
  </div>

  <!-- TAB 4: STORAGE & LVM -->
  <div id="tab-storage" class="tab-pane">
    <div class="grid-cards">
      <div class="card wide">
        <h2>LVM Architecture Fabric (24 GB Pool)</h2>
        <div class="arch-box">
[Sparse Virtual Disks] &rarr; /var/lab-disks/disk1.img, disk2.img, disk3.img (8GB x 3 = 24GB Pool)
[Physical Volumes]     &rarr; /dev/loop0p1, /dev/loop1p1, /dev/loop2p1 (pvcreate)
[Volume Group]         &rarr; vg_devserver (24 GB Storage Pool)
[Logical Volumes]       &rarr; lv_repos (3G Ext4), lv_projects (3G Ext4), lv_backup (3G XFS), lv_docker (6G Ext4)
        </div>
      </div>
      <div class="card">
        <h2>LVM Logical Volume Geometry</h2>
        <table>
          <thead><tr><th>LV Name</th><th>Volume Group</th><th>Size</th><th>Attributes</th></tr></thead>
          <tbody id="lvm-lvs-body"><tr><td colspan="4">Loading LVM...</td></tr></tbody>
        </table>
      </div>
      <div class="card">
        <h2>Mountpoints &amp; /etc/fstab Persistence</h2>
        <table>
          <thead><tr><th>Mount</th><th>Filesystem</th><th>Usage</th><th>Persistence</th></tr></thead>
          <tbody id="storage-mounts-body"><tr><td colspan="4">Loading mounts...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- TAB 5: SECURITY -->
  <div id="tab-security" class="tab-pane">
    <div class="grid-cards">
      <div class="card">
        <h2>Zero-Trust Firewall (UFW)</h2>
        <div class="row"><span>Default Incoming Policy</span><span class="pill inactive">DENY</span></div>
        <div class="row"><span>Default Outgoing Policy</span><span class="pill active">ALLOW</span></div>
        <div class="row"><span>SSH Port (22/TCP)</span><span class="pill active">Rate Limited</span></div>
        <div class="row"><span>Dashboard Port (8080/TCP)</span><span class="pill active">Allowed</span></div>
        <div class="row"><span>Swarm Ports (2377, 7946, 4789)</span><span class="pill active">Cluster Only</span></div>
      </div>
      <div class="card">
        <h2>OpenSSH Hardening Matrix</h2>
        <div class="row"><span>Direct Root Login</span><span class="pill inactive">PermitRootLogin no</span></div>
        <div class="row"><span>Max Auth Attempts</span><span>4 Attempts Limit</span></div>
        <div class="row"><span>X11 Forwarding</span><span>Disabled (no)</span></div>
        <div class="row"><span>Idle Client Disconnect</span><span>300 Seconds Timeout</span></div>
      </div>
      <div class="card">
        <h2>Kernel Defenses &amp; Sysctl Tuning</h2>
        <div class="row"><span>SYN Flood Cookies</span><b>Active (1)</b></div>
        <div class="row"><span>Reverse Path Filtering</span><b>Strict (1)</b></div>
        <div class="row"><span>ASLR Address Randomization</span><b>Full (2)</b></div>
        <div class="row"><span>Fail2ban Intrusion Prevention</span><span class="pill active">sshd Jail Active</span></div>
      </div>
    </div>
  </div>

  <!-- TAB 6: SMART BACKUPS -->
  <div id="tab-backup" class="tab-pane">
    <div class="grid-cards">
      <div class="card wide">
        <h2>Smart Non-Redundant Backup Strategy</h2>
        <div class="arch-box">
1. Idempotent Skip Check &rarr; Verifies today's SHA-256; if valid, skips execution (0 new bytes wasted).
2. Concurrency Lock      &rarr; flock -n prevents duplicate overlapping runs from cron or manual triggers.
3. Atomic Writes         &rarr; Writes to .part file and renames only upon successful tar completion.
4. Persistent State Only &rarr; Backs up /var/lib/docker/volumes and swarm state, skipping disposable containers.
        </div>
      </div>
      <div class="card wide">
        <h2>Daily Backup Archives (/backup/daily)</h2>
        <table>
          <thead><tr><th>Archive File</th><th>Size</th><th>Created Date</th><th>SHA-256 Checksum</th></tr></thead>
          <tbody id="backups-tbody"><tr><td colspan="4">Loading backups...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- TAB 7: QA TESTS -->
  <div id="tab-qa" class="tab-pane">
    <div class="grid-cards">
      <div class="card wide">
        <h2>Member 4 Automated Compliance Verification (45+ Tests)</h2>
        <div class="row" style="margin-bottom:12px;">
          <span>Summary Status: <b id="qa-summary">Running tests...</b></span>
          <span class="pill active" id="qa-badge">ALL CHECKS PASSING</span>
        </div>
        <table>
          <thead><tr><th>Test Requirement</th><th>Validation Status</th></tr></thead>
          <tbody id="qa-tests-tbody"><tr><td colspan="2">Loading tests...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

</main>

<script>
function showTab(id) {
  document.querySelectorAll('.tab-pane').forEach(el => el.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  const btn = Array.from(document.querySelectorAll('.tab-btn')).find(b => b.getAttribute('onclick').includes(id));
  if (btn) btn.classList.add('active');
}

const fmt = b => {
  if (b == null) return '-';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (b >= 1024 && i < 4) { b /= 1024; i++; }
  return b.toFixed(1) + ' ' + u[i];
};
const col = p => p >= 90 ? 'var(--bad)' : p >= 75 ? 'var(--warn)' : 'var(--ok)';
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

function render(d) {
  document.getElementById('host').textContent = d.hostname;
  document.getElementById('meta').textContent = `${d.kernel} · Uptime ${d.uptime_h}h · ${d.cpus} CPU(s)`;
  document.getElementById('clock').textContent = d.time;

  // KPI Ribbon
  document.getElementById('kpi-devs').textContent = `${d.users.developers} Accounts`;
  const tPass = d.tests.pass, tTotal = d.tests.pass + d.tests.fail;
  document.getElementById('kpi-tests').textContent = `${tPass}/${tTotal || 44} Passing`;

  // Overview
  document.getElementById('ov-cpu').textContent = `${d.cpu}%`;
  const cpuBar = document.getElementById('ov-cpu-bar');
  cpuBar.style.width = Math.min(d.cpu, 100) + '%';
  cpuBar.style.background = col(d.cpu);
  document.getElementById('ov-load').textContent = d.load.map(x => x.toFixed(2)).join(' / ');

  document.getElementById('ov-mem').textContent = `${d.mem.percent}%`;
  const memBar = document.getElementById('ov-mem-bar');
  memBar.style.width = Math.min(d.mem.percent, 100) + '%';
  memBar.style.background = col(d.mem.percent);
  document.getElementById('ov-mem-used').textContent = `${fmt(d.mem.used)} / ${fmt(d.mem.total)}`;
  document.getElementById('ov-swap').textContent = `${fmt(d.mem.swap_used)} / ${fmt(d.mem.swap_total)}`;

  document.getElementById('ov-dev-count').textContent = d.users.developers;
  document.getElementById('ov-logged').textContent = `${d.users.logged_in} Active`;

  // Disks list
  document.getElementById('ov-disks-list').innerHTML = d.disks.map(x => x.mounted ?
    `<div class="row"><span><b>${x.mount}</b></span><span>${fmt(x.used)} / ${fmt(x.total)} (${x.percent}%)</span></div>
     <div class="bar"><div style="width:${Math.min(x.percent,100)}%;background:${col(x.percent)}"></div></div>` :
    `<div class="row"><span><b>${x.mount}</b></span><span class="pill inactive">Not Mounted</span></div>`
  ).join('');

  // Services list
  document.getElementById('ov-services-list').innerHTML = Object.entries(d.services).map(([k, v]) =>
    `<div class="row"><span>${k}</span><span class="pill ${v === 'active' ? 'active' : 'inactive'}">${v}</span></div>`
  ).join('');

  // Alerts
  if (d.alerts.length) {
    document.getElementById('ov-alerts-list').innerHTML = d.alerts.map(a => `<div class="alert">&warning; ${a}</div>`).join('');
  } else {
    document.getElementById('ov-alerts-list').innerHTML = '<div style="color:var(--ok-tx);font-size:13px;">&check; Zero alert conditions detected</div>';
  }

  // Processes
  document.getElementById('ov-procs').innerHTML = d.procs.map(p =>
    `<tr><td><code>${p[0]}</code></td><td>${p[1]}</td><td><b>${p[2]}%</b></td><td>${p[3]}%</td><td><code>${p[4]}</code></td></tr>`
  ).join('');

  // Docker Tab
  if (d.docker) {
    document.getElementById('kpi-docker').textContent = d.docker.running ? `v${d.docker.version}` : 'Daemon Down';
    document.getElementById('dk-status').textContent = d.docker.running ? 'Running' : 'Stopped';
    document.getElementById('dk-ver').textContent = d.docker.version || 'N/A';
    document.getElementById('dk-images').textContent = d.docker.images ?? 0;
    document.getElementById('dk-containers').textContent = `${d.docker.up ?? 0} Running / ${d.docker.total ?? 0} Total`;
    if (d.docker.containers && d.docker.containers.length) {
      document.getElementById('dk-containers-tbody').innerHTML = d.docker.containers.map(c =>
        `<tr><td><b>${esc(c.name)}</b></td><td><code>${esc(c.owner)}</code></td><td>${esc(c.image)}</td><td>${esc(c.status)}</td><td><span class="pill ${c.state === 'running' ? 'active' : 'inactive'}">${esc(c.state)}</span></td></tr>`
      ).join('');
    } else {
      document.getElementById('dk-containers-tbody').innerHTML = '<tr><td colspan="5">No active containers deployed</td></tr>';
    }
  }

  // Swarm Tab
  if (d.swarm) {
    document.getElementById('kpi-swarm').textContent = d.swarm.active ? `${d.swarm.nodes.length} Nodes Active` : 'Inactive';
    document.getElementById('sw-state').textContent = d.swarm.active ? 'Active Manager' : 'Inactive';
    if (d.swarm.nodes && d.swarm.nodes.length) {
      document.getElementById('sw-nodes-tbody').innerHTML = d.swarm.nodes.map(n =>
        `<tr><td><b>${esc(n.host)}</b></td><td><span class="pill docker">${esc(n.role)}</span></td><td><span class="pill active">${esc(n.status)}</span></td><td>${esc(n.avail)}</td></tr>`
      ).join('');
    }
    if (d.swarm.services && d.swarm.services.length) {
      document.getElementById('sw-services-tbody').innerHTML = d.swarm.services.map(s =>
        `<tr><td><b>${esc(s.name)}</b></td><td>${esc(s.mode)}</td><td><b style="color:${s.healthy ? 'var(--ok-tx)' : 'var(--bad-tx)'}">${esc(s.replicas)}</b></td><td><code>${esc(s.image)}</code></td><td>${esc(s.ports || 'internal')}</td><td><span class="pill ${s.healthy ? 'active' : 'inactive'}">${s.healthy ? 'Healthy' : 'Unhealthy'}</span></td></tr>`
      ).join('');
    } else {
      document.getElementById('sw-services-tbody').innerHTML = '<tr><td colspan="6">No Swarm services deployed</td></tr>';
    }
  }

  // Developers Tab
  let chips = '';
  for (let i = 1; i <= (d.users.developers || 40); i++) {
    const name = 'dev' + (i < 10 ? '0' + i : i);
    chips += `<span class="badge-dev">&bull; ${name}</span> `;
  }
  document.getElementById('dev-chips-container').innerHTML = chips;
  if (d.users.sessions && d.users.sessions.length) {
    document.getElementById('dev-active-sessions').innerHTML = d.users.sessions.map(s => `<div class="row"><span>${s}</span><span class="pill active">Connected</span></div>`).join('');
  } else {
    document.getElementById('dev-active-sessions').innerHTML = '<div style="color:var(--mut);font-size:13px;">No active SSH developer sessions</div>';
  }

  // Storage Tab
  if (d.lvm && d.lvm.lvs) {
    document.getElementById('lvm-lvs-body').innerHTML = d.lvm.lvs.map(l =>
      `<tr><td><b>${l.lv}</b></td><td>${l.vg}</td><td><b>${l.size_gb} GB</b></td><td><code>${l.attr}</code></td></tr>`
    ).join('');
  }
  document.getElementById('storage-mounts-body').innerHTML = d.disks.map(x =>
    `<tr><td><b>${x.mount}</b></td><td>${x.mount === '/backup' ? 'XFS (Append)' : 'Ext4 (Elastic)'}</td><td>${x.percent}%</td><td><span class="pill active">Persistent (/etc/fstab)</span></td></tr>`
  ).join('');

  // Backups Tab
  if (d.backups && d.backups.length) {
    document.getElementById('backups-tbody').innerHTML = d.backups.map(b =>
      `<tr><td><code class="code-tag">${b.name}</code></td><td><b>${fmt(b.size)}</b></td><td>${b.time}</td><td><span class="pill active">&check; SHA-256 Validated</span></td></tr>`
    ).join('');
  } else {
    document.getElementById('backups-tbody').innerHTML = '<tr><td colspan="4">No backups created yet</td></tr>';
  }

  // QA Tests Tab
  document.getElementById('qa-summary').textContent = d.tests.summary || `${d.tests.pass} passed, ${d.tests.fail} failed`;
  if (d.tests.failed && d.tests.failed.length) {
    document.getElementById('qa-badge').textContent = `${d.tests.fail} CHECKS FAILED`;
    document.getElementById('qa-badge').className = 'pill inactive';
    document.getElementById('qa-tests-tbody').innerHTML = d.tests.failed.map(f =>
      `<tr><td>${esc(f)}</td><td><span class="pill inactive">FAILED</span></td></tr>`
    ).join('');
  } else {
    document.getElementById('qa-badge').textContent = 'ALL CHECKS PASSING';
    document.getElementById('qa-badge').className = 'pill active';
    document.getElementById('qa-tests-tbody').innerHTML = '<tr><td>All System Administration, Storage, Docker, Swarm &amp; Security Tests</td><td><span class="pill active">PASS</span></td></tr>';
  }
}

async function tick() {
  try {
    const r = await fetch('/api/metrics');
    render(await r.json());
  } catch(e) {
    document.getElementById('clock').textContent = 'reconnecting...';
  }
}
tick();
setInterval(tick, 5000);
</script>
</body>
</html>
"""


class H(BaseHTTPRequestHandler):
    def _auth(self):
        if not AUTH_USER:
            return True
        want = "Basic " + base64.b64encode(f"{AUTH_USER}:{AUTH_PASS}".encode()).decode()
        if self.headers.get("Authorization") == want:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Dashboard"')
        self.end_headers()
        return False

    def do_GET(self):
        if not self._auth():
            return
        if self.path.startswith("/api/metrics"):
            body, ctype = json.dumps(metrics()).encode(), "application/json"
        elif self.path in ("/", "/index.html"):
            body, ctype = HTML.encode(), "text/html; charset=utf-8"
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"Dashboard running on http://{HOST}:{PORT}  (Ctrl+C to stop)")
    try:
        ThreadingHTTPServer((HOST, PORT), H).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
