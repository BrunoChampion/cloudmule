"""Fake RunPod REST API for cloudmule's tests: answers the calls cloudmule makes from recorded fixtures, keeps its
pods in a state file, logs every request, and never touches RunPod. Run with `python -I`.

usage: server.py <dir>    (writes <dir>/port when it listens on 127.0.0.1)

<dir>/scenario.json (read on every request, so a test changes it between commands; missing = defaults):
  catalog_status   HTTP status of GET /catalog/gpus (403 = a key without "catalog read")
  unavailable      GPU ids whose create answers 400 "no longer any instances available"
  cost             {gpu id: USD/h} RunPod charges for a created pod (default: the catalog's secure price)
  no_public_ssh    true: pods run without a public port 22
  pods             pods that already exist (for listings): [{id, name, cost, gpu: {id}, createdAt}]
<dir>/state.json   the pods created so far (delete the file to start over)
<dir>/requests.log one line per request: "<METHOD> <path> <auth ok|BAD>", then the JSON body of a POST
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DIR = sys.argv[1]
FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
KEY = "fake-runpod-key-for-tests"
NO_INSTANCES = ("There are no longer any instances available with the requested specifications. "
                "Please refresh and try again.")


def load(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_state(state):
    with open(os.path.join(DIR, "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        url = urlparse(self.path)
        path = url.path.replace("/v2", "", 1) if url.path.startswith("/v2/") else url.path
        auth = "ok" if self.headers.get("Authorization") == f"Bearer {KEY}" else "BAD"
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode() if method == "POST" else ""
        with open(os.path.join(DIR, "requests.log"), "a", encoding="utf-8") as log:
            log.write(f"{method} {self.path} {auth}\n" + (body + "\n" if body else ""))
        if auth != "ok":
            return self.reply(401, {"error": "unauthorized"})
        sc = load("scenario.json", {})
        state = load("state.json", {"pods": [], "next": 1})
        pods = sc.get("pods", []) + state["pods"]
        if method == "GET" and path == "/catalog/gpus":
            if sc.get("catalog_status", 200) != 200:
                return self.reply(sc["catalog_status"], {"error": "forbidden"})
            cloud = (parse_qs(url.query).get("cloud") or ["SECURE"])[0].lower()
            with open(os.path.join(FIX, f"runpod-catalog-{cloud}.json"), encoding="utf-8") as f:
                return self.reply(200, json.load(f))
        if method == "POST" and path == "/pods":
            req = json.loads(body)
            gid = req["gpu"]["id"]
            if gid in sc.get("unavailable", []):
                return self.reply(400, {"error": NO_INSTANCES})
            with open(os.path.join(FIX, "runpod-catalog-secure.json"), encoding="utf-8") as f:
                price = next((g["price"]["secure"] for g in json.load(f) if g["id"] == gid), 0.5)
            pod = {"id": f"fakepod{state['next']}", "name": req["name"], "cost": sc.get("cost", {}).get(gid, price),
                   "cloud": req["cloud"], "gpu": {"id": gid, "count": 1}, "desiredStatus": "RUNNING"}
            state["next"] += 1
            state["pods"].append(pod)
            save_state(state)
            return self.reply(201, pod)
        if method == "GET" and path == "/pods":
            return self.reply(200, pods)
        if path.startswith("/pods/"):
            pid = path.split("/")[2]
            pod = next((p for p in pods if p["id"] == pid), None)
            if pod is None:
                return self.reply(404, {"error": "pod not found"})
            if method == "DELETE":
                state["pods"] = [p for p in state["pods"] if p["id"] != pid]
                save_state(state)
                return self.reply(200, {})
            ports = [{"ip": "100.64.0.1", "private": 22, "public": None, "type": "tcp"}]
            if not sc.get("no_public_ssh"):
                ports = [{"ip": "127.0.0.1", "private": 22, "public": 2222, "type": "tcp", "isIpPublic": True}]
            return self.reply(200, dict(pod, status="RUNNING", runtime={"ports": ports}))
        return self.reply(404, {"error": f"fake runpod: unhandled {method} {path}"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
