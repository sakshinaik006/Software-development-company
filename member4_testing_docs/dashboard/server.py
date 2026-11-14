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


HTML = r"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Dev Server Dashboard</title>
<style>
:root{--bg:#0f172a;--card:#1e293b;--tx:#e2e8f0;--mut:#94a3b8;--ok:#22c55e;--warn:#f59e0b;--bad:#ef4444;--acc:#38bdf8}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--tx)}
header{padding:16px 24px;background:#111c33;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px}
h1{font-size:20px;margin:0}small{color:var(--mut)}
main{padding:20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:16px}
.card{background:var(--card);border-radius:12px;padding:16px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 12px}
.big{font-size:32px;font-weight:700}
.bar{height:10px;background:#334155;border-radius:6px;overflow:hidden;margin:6px 0 10px}
.bar>div{height:100%;background:var(--ok);transition:width .5s}
.row{display:flex;justify-content:space-between;font-size:14px;margin:4px 0;gap:8px}
.pill{padding:2px 10px;border-radius:99px;font-size:12px;font-weight:600}
.active{background:#14532d;color:#86efac}.inactive,.failed,.n\/a{background:#7f1d1d;color:#fca5a5}.n\/a{background:#334155;color:#94a3b8}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:4px 6px;border-bottom:1px solid #334155}
.wide{grid-column:1/-1}.alert{color:var(--warn);font-size:13px;margin:3px 0}.fail{color:var(--bad);font-size:13px}
code{color:var(--acc);font-size:12px}
</style></head><body>
<header><div><h1>🖥️ <span id="host">Dev Server</span> – Monitoring Dashboard</h1>
<small id="meta"></small></div><small>Auto-refresh 5 s · <span id="clock"></span></small></header>
<main id="m"><div class="card">Loading…</div></main>
<script>
const fmt=b=>{if(b==null)return'-';const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<4){b/=1024;i++}return b.toFixed(1)+' '+u[i]};
const col=p=>p>=90?'var(--bad)':p>=75?'var(--warn)':'var(--ok)';
const bar=p=>`<div class="bar"><div style="width:${Math.min(p,100)}%;background:${col(p)}"></div></div>`;
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pill=s=>`<span class="pill ${s}">${s}</span>`;
function render(d){
 document.getElementById('host').textContent=d.hostname;
 document.getElementById('meta').textContent=`Kernel ${d.kernel} · Uptime ${d.uptime_h} h · ${d.cpus} CPU(s)`;
 document.getElementById('clock').textContent=d.time;
 const t=d.tests, tt=t.pass+t.fail;
 let h='';
 h+=`<div class="card"><h2>CPU usage</h2><div class="big">${d.cpu}%</div>${bar(d.cpu)}
   <div class="row"><span>Load avg (1/5/15)</span><span>${d.load.map(x=>x.toFixed(2)).join(' / ')}</span></div></div>`;
 h+=`<div class="card"><h2>Memory</h2><div class="big">${d.mem.percent}%</div>${bar(d.mem.percent)}
   <div class="row"><span>${fmt(d.mem.used)} / ${fmt(d.mem.total)}</span><span>Swap ${fmt(d.mem.swap_used)} / ${fmt(d.mem.swap_total)}</span></div></div>`;
 h+=`<div class="card"><h2>Developers</h2><div class="big">${d.users.developers}</div>
   <div class="row"><span>Logged in now</span><b>${d.users.logged_in}</b></div>
   ${d.users.sessions.map(s=>`<div class="row"><small>${s}</small></div>`).join('')}
   <div class="row"><span>Failed SSH logins</span><b>${d.failed_ssh??'n/a'}</b></div></div>`;
 h+=`<div class="card"><h2>Storage (mounted volumes)</h2>`+d.disks.map(x=>x.mounted?
   `<div class="row"><span>${x.mount}</span><span>${fmt(x.used)} / ${fmt(x.total)} (${x.percent}%)</span></div>${bar(x.percent)}`:
   `<div class="row"><span>${x.mount}</span><span class="pill inactive">not mounted</span></div>`).join('')+`</div>`;
 h+=`<div class="card"><h2>LVM</h2>`+(d.lvm.vg?`<div class="row"><span>VG <b>${d.lvm.vg.name}</b></span><span>${d.lvm.vg.size} GB total · ${d.lvm.vg.free} GB free</span></div>`:'<small>No LVM data (run as root)</small>')+
   `<table><tr><th>LV</th><th>Size</th><th>Attr</th></tr>${d.lvm.lvs.map(l=>`<tr><td>${l.lv}</td><td>${l.size_gb} GB</td><td><code>${l.attr}</code></td></tr>`).join('')}</table></div>`;
 h+=`<div class="card"><h2>Services</h2>`+Object.entries(d.services).map(([k,v])=>`<div class="row"><span>${k}</span>${pill(v)}</div>`).join('')+`</div>`;
 if(d.docker){h+=`<div class="card wide"><h2>Docker (shared daemon)</h2>`+(d.docker.running?
   `<div class="row"><span>Engine ${esc(d.docker.version)}</span><span>${d.docker.up} running / ${d.docker.total} containers · ${d.docker.images} images</span></div>
   <table><tr><th>Container</th><th>Owner</th><th>Image</th><th>Status</th></tr>${d.docker.containers.map(c=>`<tr><td>${esc(c.name)}</td><td>${esc(c.owner)}</td><td>${esc(c.image)}</td><td>${esc(c.status)}</td></tr>`).join('')||'<tr><td colspan=4>No containers yet</td></tr>'}</table>`
   :`<span class="pill inactive">daemon not running</span>`)+`</div>`;}
 if(d.swarm){h+=`<div class="card wide"><h2>Orchestration (Docker Swarm)</h2>`+(d.swarm.active?
   `<div class="row"><span>${d.swarm.nodes.length} node(s) · ${d.swarm.services.length} service(s)</span><span>${d.swarm.unhealthy?`<span class="pill inactive">${d.swarm.unhealthy} unhealthy</span>`:'<span class="pill active">all healthy</span>'}</span></div>
   <table><tr><th>Node</th><th>Role</th><th>Status</th><th>Availability</th></tr>${d.swarm.nodes.map(n=>`<tr><td>${esc(n.host)}</td><td>${esc(n.role)}</td><td>${esc(n.status)}</td><td>${esc(n.avail)}</td></tr>`).join('')}</table><br>
   <table><tr><th>Service</th><th>Mode</th><th>Replicas</th><th>Image</th><th>Ports</th></tr>${d.swarm.services.map(x=>`<tr><td>${esc(x.name)}</td><td>${esc(x.mode)}</td><td style="color:${x.healthy?'var(--ok)':'var(--bad)'}">${esc(x.replicas)}</td><td>${esc(x.image)}</td><td>${esc(x.ports)}</td></tr>`).join('')||'<tr><td colspan=5>No services deployed</td></tr>'}</table>`
   :`<small>Swarm not initialised (run member1_sysadmin/06_swarm.sh)</small>`)+`</div>`;}
 h+=`<div class="card"><h2>Test results (Member 4)</h2><div class="big" style="color:${t.fail?'var(--bad)':'var(--ok)'}">${t.pass}/${tt||'-'}</div>
   <small>${t.summary}</small>${t.failed.map(f=>`<div class="fail">✗ ${f}</div>`).join('')}</div>`;
 h+=`<div class="card"><h2>Alerts</h2>`+(d.alerts.length?d.alerts.map(a=>`<div class="alert">⚠ ${a}</div>`).join(''):'<small>No recent alerts ✔</small>')+`</div>`;
 h+=`<div class="card wide"><h2>Backups (/backup/daily)</h2><table><tr><th>File</th><th>Size</th><th>Created</th></tr>`+
   (d.backups.map(b=>`<tr><td>${b.name}</td><td>${fmt(b.size)}</td><td>${b.time}</td></tr>`).join('')||'<tr><td colspan=3>No backups yet</td></tr>')+`</table></div>`;
 h+=`<div class="card"><h2>Cron schedule</h2>`+(d.cron.map(c=>`<div><code>${c.replace(/</g,'&lt;')}</code></div>`).join('')||'<small>Not installed</small>')+`</div>`;
 h+=`<div class="card"><h2>Top processes</h2><table><tr><th>PID</th><th>User</th><th>CPU</th><th>MEM</th><th>Cmd</th></tr>${d.procs.map(p=>`<tr>${p.map(c=>`<td>${c}</td>`).join('')}</tr>`).join('')}</table></div>`;
 document.getElementById('m').innerHTML=h;
}
async function tick(){try{const r=await fetch('/api/metrics');render(await r.json())}catch(e){document.getElementById('clock').textContent='connection lost'}}
tick();setInterval(tick,5000);
</script></body></html>"""


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
