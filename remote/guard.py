"""Cost guard. Runs ON the server every 5 minutes (systemd timer armed by `arm_guard` in bin/lib.sh).

usage: guard.py <server_id> <mode oneshot|session> <idle_minutes> <max_hours>

The server is SHARED by every project (leases in /root/cloudmule/leases/); activity from any project keeps it alive.

Deletes the server through the Hetzner API when either:
  - it has been idle for <idle_minutes>: no SSH connection and no job running (any remote_job — its command
    line mentions /root/cloudmule/jobs/ —, hyperframes, Chrome, ffmpeg, pnpm, node builds, gradle, apt), or
  - it has been up for <max_hours>.
In mode "session" it first saves the whole disk as the shared workspace snapshot (role=workspace, scope=shared),
so no project loses anything; the next `cloudmule start` restores it.

The API token lives in /run/cloudmule/token (RAM disk), so it is never written into a snapshot.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

API = "https://api.hetzner.cloud/v1"
SID, MODE = sys.argv[1], sys.argv[2]
IDLE_MIN, MAX_H = float(sys.argv[3]), float(sys.argv[4])
STAMP = "/run/cloudmule/last_active"
JOBS = r"/root/cloudmule/jobs/|hyperframes|chrome-headless|ffmpeg|pnpm|gradle|java|apt-get|dpkg"


def log(msg):
    print(msg, flush=True)
    subprocess.run(["logger", "-t", "cloudmule-guard", msg])


def busy():
    ssh = subprocess.run(["ss", "-tnH", "state", "established", "( sport = :22 )"],
                         capture_output=True, text=True).stdout.strip()
    jobs = subprocess.run(["pgrep", "-f", JOBS], capture_output=True).returncode == 0
    return bool(ssh) or jobs


now = time.time()
if busy() or not os.path.exists(STAMP):
    with open(STAMP, "w") as f:
        f.write(str(now))
idle_min = (now - float(open(STAMP).read())) / 60
uptime_h = float(open("/proc/uptime").read().split()[0]) / 3600
if idle_min < IDLE_MIN and uptime_h < MAX_H:
    sys.exit(0)

TOKEN = open("/run/cloudmule/token").read().strip()


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


log(f"self-destruct: idle {idle_min:.0f} min (limit {IDLE_MIN:.0f}), up {uptime_h:.2f} h (limit {MAX_H:.0f})")
if MODE == "session":
    try:
        subprocess.run(["sync"])
        labels = {"managed-by": "cloudmule", "role": "workspace", "scope": "shared"}
        try:   # keep the user's server choice (chosen-type/-by/-at) on the snapshot, as `end --keep` does
            own = call("GET", f"/servers/{SID}")["server"].get("labels") or {}
            labels.update({k: v for k, v in own.items() if k.startswith("chosen-")})
        except Exception as e:
            log(f"could not read the server's labels: {e}")
        r = call("POST", f"/servers/{SID}/actions/create_image", {
            "type": "snapshot",
            "description": f"cloudmule workspace {time.strftime('%Y-%m-%d %H:%M')} (auto, guard)",
            "labels": labels,
        })
        aid = r["action"]["id"]
        for _ in range(180):  # up to 30 min
            st = call("GET", f"/actions/{aid}")["action"]["status"]
            if st != "running":
                log(f"snapshot {st}")
                break
            time.sleep(10)
    except Exception as e:  # the cost guard wins: delete anyway
        log(f"snapshot failed: {e}")
log("deleting server")
call("DELETE", f"/servers/{SID}")
