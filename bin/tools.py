"""Helpers for bin/cloudmule (run with `python -I`).

JSON from `hcloud … -o json` on stdin:
  menu [requirements] [--no-escape] [--last-choice <type>]  server types table for the user: fit verdict + reason, price, location; fitting
                                      rows with a bigger disk than the disk floor (or, with no workspace, than the
                                      smallest fitting disk) say what they would do to it; a "Cheaper with --fresh"
                                      line when the disk floor shuts out a cheaper type (unless --no-escape); last line
                                      "RECOMMENDED: <type> <location> <eur/h>" (or "RECOMMENDED: none")
  candidates --types "<t…>" [requirements]  fitting (type, location, EUR/h) in the given order, cheapest available
                                      location first; none fits -> "NO_FITTING_SERVER: <reasons>" on stderr, exit 3
  below [requirements]                a server (describe JSON): why it is below the requirements (empty if not)
  image-info                          an image (describe JSON): "<disk_size GB> <architecture>"
  server-type                         a server (describe JSON): "<type>, <vCPU> / <RAM> / <disk> <cpu kind>"
  server-disk                         a server (describe JSON): "<disk GB> <architecture>"
  choice [--type|--who|--labels]      a server or snapshot (describe JSON): the user's server choice in its labels
  requirements: --locations "<l…>" --min-ram <GB> --min-cpus <n> --min-disk <GB> --archs "<x86 arm>"
                --workspace-disk <GB> --workspace-arch <x86|arm>   (a snapshot restores only on a disk >= its own)
  field <name> | label <key>          one field / one label of a JSON object
  ages                                servers: name, status, hours up, hours billed
  overdue <hours>                     names of servers older than <hours>

No stdin:
  guide                               the "How to choose" guide printed before the menu
  usage <usage.tsv> <keep_days> [project] [target]   per project and job: runs, peak RAM, RAM wait, cores, longest
  prune-logs <logs dir> <keep_days>   deletes job logs (*.log) older than keep_days

Stdin = a server's measurement lines (key=value pairs, see MEASURE in bin/lib.sh):
  usage-add <usage.tsv> <keep_days> <project> <target> <job>   appends one usage line per measurement

Sync (patterns are space-separated):
  find-prune "<exclude>" "<seeds>"    GNU find arguments that prune excluded directory names (never a seed's parent)
  sync-plan <local_dir> <push_out> <delete_out> --exclude "<pats>" --seeds "<pats>" [--with-generated]
      remote manifest on stdin ("path<TAB>size<TAB>mtime"); writes the files to upload / to delete on the server.

Pattern rules: a pattern without "/" matches any path component (a directory or file name, globs allowed);
a pattern with "/" matches the whole relative path (fnmatch). Seeds always win over excludes.
Extra exclude patterns can live in <local_dir>/.cloudmuleignore (one per line).

RunPod GPU pods (REST API, key in RUNPOD_API_KEY, never printed). Limits: --max-usd <USD/h> --max-minutes <min>
--day-left <USD> [--min-vram <GB>]. Pod records (one JSON file per pod this computer created): --records <dir>;
usage lines: --usage <usage.tsv> --keep-days <n>.
  rp-gpus --clouds "SECURE COMMUNITY" [limits] [--last-gpu <id> --last-cloud <c>]   the GPU menu; last line
                                      "RECOMMENDED: <gpu id> <cloud> <usd/h>" (or "RECOMMENDED: none (…)")
  rp-launch --candidates "<id>[,<id>…]" --cloud <c> [limits] --name <pod> --image <i> --disk <GB>
            --pubkey-file <f> --run <token> --project <p> --target <t|-> --job <j> [records, usage] [--dry-run]
                                      creates the first candidate that fits; prints "POD<TAB>id<TAB>usd/h<TAB>gpu"
                                      (--dry-run: "WOULD_CREATE: <gpu> <cloud> <usd/h> <max usd>"); refusals on stderr
                                      (NEEDS_GPU_CHOICE, ABOVE_HOURLY_CAP, DAILY_CAP_REACHED,
                                      NO_GPU_AVAILABLE, NO_FITTING_GPU), exit 3
  rp-wait <pod id> --timeout <s> --interval <s>   "ip port" of its public SSH; NO_PUBLIC_SSH on stderr, exit 4
  rp-delete --run <token> [records, usage] [--measure <file>]   deletes the run's pods, one usage line each
  rp-reap --run <token> --after <s> [records, usage]   the local watchdog: sleeps, then rp-delete
  rp-pods --max-minutes <m> [records, usage] [--reap] [--worst]   the account's pods; --reap deletes cloudmule
                                      pods up longer than max-minutes + 5; --worst prints only "RUNNING_WORST_USD x"
  rp-spend <usage.tsv>                today's GPU spend in USD (from the usage lines)
"""
import fnmatch
import json
import math
import os
import re
import shlex
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def opts(args):
    """--key value pairs and bare --flags (a value may be an empty string)."""
    o, i = {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--") and i + 1 < len(args) and not args[i + 1].startswith("--"):
            o[a[2:]] = args[i + 1]
            i += 2
        elif a.startswith("--"):
            o[a[2:]] = True
            i += 1
        else:
            i += 1
    return o


def gb(x):
    return f"{float(x):g}"


class Reqs:
    def __init__(self, o):
        self.ram = float(o.get("min-ram") or 0)
        self.cpus = int(float(o.get("min-cpus") or 0))
        self.disk = int(float(o.get("min-disk") or 0))
        self.archs = str(o.get("archs") if o.get("archs") is not None else "x86 arm").split()
        self.ws_disk = int(float(o.get("workspace-disk") or 0))
        self.ws_arch = str(o.get("workspace-arch") or "")
        self.locs = str(o.get("locations") or "").split()


FLOOR = "floor"   # the reason kind of "this type's disk is below the disk floor"


def fit_reasons(t, r):
    """Why server type t does not meet the requirements (hardware + saved workspace), ignoring availability:
    a list of (kind, text); kind FLOOR marks the disk floor, the only reason --fresh removes by itself."""
    why = []
    if float(t["memory"]) < r.ram:
        why.append(("ram", f"ram < {gb(r.ram)} GB"))
    if int(t["cores"]) < r.cpus:
        why.append(("cpus", f"cpus < {r.cpus}"))
    if int(t["disk"]) < r.disk:
        why.append(("disk", f"disk < {r.disk} GB"))
    if t["architecture"] not in r.archs:
        why.append(("arch", f"arch {t['architecture']} (project needs {'/'.join(r.archs) or 'nothing available'})"))
    if r.ws_disk and int(t["disk"]) < r.ws_disk:
        why.append((FLOOR, f"below disk floor {r.ws_disk} GB (or --fresh)"))
    if r.ws_arch and t["architecture"] != r.ws_arch:
        why.append(("ws-arch", f"workspace is {r.ws_arch} (or --fresh)"))
    return why


def texts(why):
    return "; ".join(text for _, text in why)


GUIDE = """How to choose (one server, shared by all your projects; billed per started hour while it exists):
- CPU: shared (CX, CPX) is cheapest, its speed varies with neighbours' load; dedicated (CCX) gives full cores,
  steadier for long renders and builds.
- RAM: pick what your jobs actually need (`cloudmule usage` shows what they peaked at); more RAM is most of what
  a bigger server costs.
- Disk: the workspace restores only on a disk at least as big as the one it was saved from (the disk floor),
  so a bigger disk than you need raises the floor for every later server.
- ARM (CAX): cheapest per core, but some modules (ffmpeg) are x86 only.
- The saved workspace costs cents per GB per month: negligible next to server hours."""


CHOICE_KEYS = ("chosen-type", "chosen-by", "chosen-at")   # labels of the user's server choice (bin/lib.sh)


def choice(data, form):
    """The server choice recorded in a server's or snapshot's labels. form: "" -> "<type> (by <p>, <date>)" or
    "none yet"; --type -> the type or ""; --who -> "<p> on <date>" or ""; --labels -> "k=v k=v k=v" or ""."""
    labels = data.get("labels") or {}
    c = {k: labels.get(k, "") for k in CHOICE_KEYS}
    if not c["chosen-type"]:
        return "none yet" if not form else ""
    if form == "--type":
        return c["chosen-type"]
    if form == "--who":
        return f"{c['chosen-by'] or '?'} on {c['chosen-at'] or '?'}"
    if form == "--labels":
        return " ".join(f"{k}={v}" for k, v in c.items() if v)
    return f"{c['chosen-type']} (by {c['chosen-by'] or '?'}, {c['chosen-at'] or '?'})"


def evaluate(t, r):
    price = {p["location"]: float(p["price_hourly"]["gross"]) for p in t.get("prices", []) if p["location"] in r.locs}
    avail = sorted((l["name"] for l in t.get("locations", []) if l.get("available") and l["name"] in price),
                   key=lambda l: price[l])
    why = fit_reasons(t, r) + ([] if avail else [("unavailable", "unavailable")])
    best = avail[0] if avail else (min(price, key=price.get) if price else "")
    return {"t": t, "price": price, "avail": avail, "why": why, "best": best}


def eur(e):
    return e["price"][e["best"]]


def disk(e):
    return int(e["t"]["disk"])


def floor_note(e, ref, rows, r):
    """Verdict suffix for a fitting row whose disk is above the reference (the disk floor, or the smallest fitting
    disk when there is no workspace): the floor it would leave and how many available types that shuts out."""
    arch = e["t"]["architecture"]
    lost = sum(1 for x in rows if x["avail"] and x["t"]["architecture"] == arch and ref <= disk(x) < disk(e))
    if not lost:   # nothing available would be lost: no warning
        return ""
    what = f"raises disk floor {ref} -> {disk(e)} GB" if r.ws_disk else f"sets disk floor to {disk(e)} GB"
    return f"; {what} ({lost} type{'' if lost == 1 else 's'} lost)"


def escape_line(rows, fit):
    """The cheapest available type kept out only by the disk floor, when it beats the recommendation."""
    shut_out = sorted((e for e in rows if e["avail"] and e["why"] and all(k == FLOOR for k, _ in e["why"])), key=eur)
    if not shut_out or (fit and eur(shut_out[0]) >= eur(fit[0])):
        return
    e = shut_out[0]
    saves = f" (saves {eur(fit[0]) - eur(e):.4f} EUR/h)" if fit else " (nothing fits without it)"
    print(f"Cheaper with --fresh: {e['t']['name']} {eur(e):.4f} EUR/h{saves}. One-time cost: every project")
    print(f"  uploads and installs again on the first start; the next end --keep lowers the disk floor to "
          f"{disk(e)} GB.")


def menu(data, o):
    r = Reqs(o)
    rows = [evaluate(t, r) for t in data if not t.get("deprecated")]
    rows = [e for e in rows if e["price"]]   # offered in at least one allowed location
    rows.sort(key=lambda e: (bool(e["why"]), any(k == "unavailable" for k, _ in e["why"]), eur(e)))
    fit = [e for e in rows if not e["why"]]
    # the disk floor each choice is compared with: the saved workspace's, or the smallest disk that fits
    ref = r.ws_disk or (min(disk(e) for e in fit) if fit else 0)
    print(f"{'TYPE':<8}{'VCPU':>5}{'RAM':>8}{'DISK':>9}  {'CPU':<10}{'ARCH':<6}{'LOCATION':<10}{'EUR/H':>8}  VERDICT")
    for e in rows:
        t = e["t"]
        mark = " (last choice)" if t["name"] == o.get("last-choice") else ""
        verdict = "no: " + texts(e["why"]) if e["why"] else "fits" + floor_note(e, ref, rows, r) + mark
        loc = e["best"] if e["avail"] else "-"
        print(f"{t['name']:<8}{t['cores']:>5}{gb(t['memory']) + ' GB':>8}{str(t['disk']) + ' GB':>9}  "
              f"{t['cpu_type']:<10}{t['architecture']:<6}{loc:<10}{eur(e):>8.4f}  {verdict}")
    print("Prices include VAT, per started hour.")
    print(f"{len(fit)} of {len(rows)} server types fit this project right now.")
    if not o.get("no-escape"):
        escape_line(rows, fit)
    if fit:
        print(f"RECOMMENDED: {fit[0]['t']['name']} {fit[0]['best']} {eur(fit[0]):.4f}")
    else:
        print("RECOMMENDED: none (nothing available fits; lower the project's MIN_* settings, try other LOCATIONS, "
              "or --fresh if the saved workspace is the limit)")


def candidates(data, o):
    r = Reqs(o)
    by = {t["name"]: t for t in data if not t.get("deprecated")}
    out, why = [], []
    for name in str(o.get("types") or "").split():
        t = by.get(name)
        if not t:
            why.append(f"{name}: unknown server type")
            continue
        e = evaluate(t, r)
        if e["why"]:
            why.append(f"{name}: " + texts(e["why"]))
            continue
        out += [f"{name} {loc} {e['price'][loc]:.4f}" for loc in e["avail"]]
    if not out:
        sys.stderr.write("NO_FITTING_SERVER: " + (" | ".join(why) or "no server type given") + "\n")
        sys.exit(3)
    print("\n".join(out))


def age_h(created):
    return (datetime.now(timezone.utc) - datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds() / 3600


class Rules:
    def __init__(self, exclude, seeds, local_dir=None):
        self.ex = exclude.split()
        self.seeds = seeds.split()
        if local_dir:
            ign = os.path.join(local_dir, ".cloudmuleignore")
            if os.path.exists(ign):
                self.ex += [l.strip() for l in open(ign, encoding="utf-8") if l.strip() and not l.startswith("#")]
        self.seed_dirs = set()
        for s in self.seeds:
            parts = s.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                self.seed_dirs.add("/".join(parts[:i]))

    def is_seed(self, p):
        return any(fnmatch.fnmatch(p, s) for s in self.seeds)

    def excluded(self, p):
        parts = p.split("/")
        for pat in self.ex:
            if "/" in pat:
                if fnmatch.fnmatch(p, pat) or fnmatch.fnmatch(p, pat.rstrip("/") + "/*"):
                    return True
            elif any(fnmatch.fnmatch(c, pat) for c in parts):
                return True
        return False

    def in_scope(self, p):
        return self.is_seed(p) or not self.excluded(p)

    def prune_dir(self, rel):  # rel = "a/b" (no trailing slash)
        return rel not in self.seed_dirs and self.excluded(rel)


def local_manifest(root, rules):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root).replace("\\", "/")
        rel = "" if rel == "." else rel + "/"
        dirnames[:] = [d for d in dirnames if not rules.prune_dir(rel + d)]
        for f in filenames:
            p = rel + f
            if rules.in_scope(p):
                st = os.stat(os.path.join(dirpath, f))
                out[p] = (st.st_size, int(st.st_mtime))
    return out


def opt(args, name, default=""):
    return args[args.index(name) + 1] if name in args else default


def sync_plan(args):
    local_dir, push_out, del_out = args[0], args[1], args[2]
    rules = Rules(opt(args, "--exclude"), opt(args, "--seeds"), local_dir)
    with_generated = "--with-generated" in args
    local = local_manifest(local_dir, rules)
    remote = {}
    for line in sys.stdin.read().splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and rules.in_scope(parts[0]):
            remote[parts[0]] = (int(parts[1]), int(float(parts[2])))
    push = [p for p, v in sorted(local.items())
            if p not in remote or ((with_generated or not rules.is_seed(p)) and remote[p] != v)]
    delete = sorted(p for p in remote if p not in local and not rules.is_seed(p))
    for path, items in ((push_out, push), (del_out, delete)):
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("".join(p + "\n" for p in items))
    mb = sum(local[p][0] for p in push) / 1048576
    print(f"{len(push)} file(s) to upload ({mb:.1f} MB), {len(delete)} to delete on the server")
    for p in push[:12]:
        print("  +", p)
    if len(push) > 12:
        print(f"  … and {len(push) - 12} more")
    for p in delete[:12]:
        print("  -", p)


# ---------------------------------------------------------------- job usage (logs/usage.tsv)
# One tab-separated line per finished remote job (raw units; converted when reported):
USAGE_FIELDS = ("date",       # when it ended, local time, YYYY-MM-DDTHH:MM
                "project", "target", "job",   # target "-" if none
                "type",       # server type
                "seconds",    # duration
                "peak_mb",    # the job's peak RAM (its cgroup's memory.peak: file cache included)
                "ram_mb",     # the server's RAM (MemTotal)
                "cpu_s",      # CPU time of all its processes
                "vcpus",      # the server's vCPUs
                "exit",       # exit code
                "stall_s",    # time its tasks stalled for lack of memory (memory.pressure "some")
                "provider",   # hetzner (the shared server) or runpod (a GPU pod; then type is the GPU id)
                "billed_s",   # runpod: how long the pod existed (n/a for hetzner: billed per server hour)
                "cost_usd")   # runpod: estimated cost of the pod, USD/h x billed_s (n/a for hetzner)
NUMERIC = ("seconds", "peak_mb", "ram_mb", "cpu_s", "vcpus", "exit", "stall_s", "billed_s")
OLD_FIELDS = 12   # lines written before GPU pods existed: hetzner, nothing billed per line


def usage_line_ok(u):
    return (all(u[k] == "n/a" or u[k].lstrip("-").isdigit() for k in NUMERIC)
            and (u["cost_usd"] == "n/a" or re.fullmatch(r"\d+(\.\d+)?", u["cost_usd"]) is not None))


def parse_usage(line):
    """One usage.tsv line as a dict, or None if it is not one (an older 12-field line counts, as hetzner)."""
    parts = line.split("\t")
    if len(parts) == OLD_FIELDS:
        parts += ["hetzner", "n/a", "n/a"]
    if len(parts) != len(USAGE_FIELDS):
        return None
    u = dict(zip(USAGE_FIELDS, parts))
    return u if usage_line_ok(u) else None


def read_usage(path, keep_days, prune=True):
    """The valid usage lines younger than keep_days. With prune, rewrites the file without the older ones
    (through a temporary file, so a reader never sees half a file)."""
    if not os.path.exists(path):
        return []
    cutoff = datetime.now() - timedelta(days=keep_days)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    kept, old = [], 0
    for line in lines:
        u = parse_usage(line)
        if u is None:
            continue   # not a usage line (hand-edited, or an unknown format): ignored
        try:
            young = datetime.fromisoformat(u["date"]) >= cutoff
        except ValueError:
            continue
        if young:
            kept.append(u)
        else:
            old += 1
    if prune and old:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as out:
            out.write("".join("\t".join(u[k] for k in USAGE_FIELDS) + "\n" for u in kept))
        os.replace(tmp, path)
    return kept


def scaled(value, divisor):
    return "n/a" if value in ("", "n/a") else str(round(int(value) / divisor))


def usage_add(args):
    """usage-add <usage.tsv> <keep_days> <project> <target> <job>; stdin: the server's measurement lines
    (key=value pairs, see MEASURE in bin/lib.sh). Appends one usage line per measurement."""
    path, keep, project, target, job = args[0], float(args[1]), args[2], args[3] or "-", args[4]
    out = []
    for raw in sys.stdin.read().splitlines():
        m = measurement(raw)
        if not m:
            continue
        end = int(m["end"])
        out.append([datetime.fromtimestamp(end).strftime("%Y-%m-%dT%H:%M"), project, target, job,
                    m.get("type") or "unknown", str(end - int(m["start"]))] + measured_fields(m)
                   + ["hetzner", "n/a", "n/a"])
    append_usage(path, keep, out)


def measured_fields(m):
    """peak_mb … stall_s of a usage line, from a measurement ({} -> all n/a)."""
    return [scaled(m.get("peak_bytes", ""), 1048576), scaled(m.get("mem_kb", ""), 1024),
            scaled(m.get("cpu_usec", ""), 1000000), m.get("vcpus") or "n/a", m.get("exit") or "n/a",
            scaled(m.get("stall_usec", ""), 1000000)]


def measurement(raw):
    """One measurement line (key=value pairs, see MEASURE in bin/lib.sh) as a dict; {} if it is not one."""
    m = dict(kv.split("=", 1) for kv in raw.split() if "=" in kv)
    return m if m.get("start", "").isdigit() and m.get("end", "").isdigit() else {}


def append_usage(path, keep, out):
    """Appends usage lines (lists of fields) to usage.tsv."""
    if not out:
        return
    # appending is what concurrent sessions do; rewriting (dropping old lines) is left to `usage` and to a weekly
    # catch-up here, so two sessions rarely rewrite and append at the same moment
    with open(path, "a", encoding="utf-8", newline="\n") as f:
        f.write("".join("\t".join(line) + "\n" for line in out))
    with open(path, encoding="utf-8") as f:
        first = f.readline().split("\t")[0]
    try:
        stale = datetime.fromisoformat(first) < datetime.now() - timedelta(days=keep + 7)
    except ValueError:
        stale = False
    if stale:
        read_usage(path, keep)


def usage_report(args):
    """usage <usage.tsv> <keep_days> [project] [target]: per project and job, runs, highest peak RAM, RAM wait,
    cores used, longest run, GPU cost and time, server types or GPUs; then the GPU spend."""
    path, keep = args[0], float(args[1])
    project, target = (args[2:3] or [""])[0], (args[3:4] or [""])[0]
    rows = [u for u in read_usage(path, keep)
            if (not project or u["project"] == project) and (not target or u["target"] == target)]
    if not rows:
        print(f"No job usage recorded yet{' for ' + project if project else ''} (last {keep:g} days). Every remote "
              f"job records one line when it ends.")
        return
    jobs = {}
    for u in rows:
        jobs.setdefault((u["project"], u["job"]), []).append(u)
    print(f"Job usage, last {keep:g} days ({path}):")
    print(f"{'PROJECT':<12}{'JOB':<18}{'RUNS':>5}  {'PEAK RAM':<15}{'RAM WAIT':<10}{'CORES USED':<24}{'LONGEST':<9}"
          f"{'GPU COST':<20}  TYPES")
    for (p, j), us in sorted(jobs.items()):
        longest = f"{max(int(u['seconds']) for u in us) / 60:.0f} min"
        # ", " between types: a GPU id has spaces
        types = ", ".join(sorted({u["type"] + (" (runpod)" if is_pod(u) else "") for u in us}))
        print(f"{p:<12}{j:<18}{len(us):>5}  {peak_ram(us):<15}{ram_wait(us):<10}{cores_used(us):<24}{longest:<9}"
              f"{gpu_spend(us):<20}  {types}")
    measured = [u for u in rows if u["peak_mb"] != "n/a"]
    if measured:
        top = max(measured, key=lambda u: int(u["peak_mb"]))
        where = " ".join(x for x in (top["project"], top["target"], top["job"]) if x != "-")
        print(f"Highest peak RAM: {int(top['peak_mb']) / 1024:.1f} GB ({where}).")
    print("PEAK RAM includes file cache the kernel frees when needed; RAM WAIT is how long the job stalled for lack")
    print("of memory: near 0 s means the RAM was enough. Jobs that run at the same time on the shared server add up.")
    pods = [u for u in rows if is_pod(u)]
    if pods:
        print(f"GPU pods (RunPod): {gpu_spend(pods)} in these {keep:g} days, {gpu_spend(of_today(pods), none="0.00 USD / 0 min")} today. "
              f"GPU COST is cloudmule's estimate (USD/h x minutes")
        print("the pod existed); RunPod's billing is authoritative.")


def gpu_spend(us, none="-"):
    """What the GPU pods among these usage lines cost and how long they existed, "0.15 USD / 15 min" (`none` when
    no line is a pod's)."""
    if not any(is_pod(u) for u in us):
        return none
    pods = [u for u in us if is_pod(u)]
    usd_total = sum(float(u["cost_usd"]) for u in pods if u["cost_usd"] != "n/a")
    minutes = sum(int(u["billed_s"]) for u in pods if u["billed_s"] != "n/a") / 60
    return f"{usd_total:.2f} USD / {minutes:.0f} min"


def peak_ram(us):
    """The highest peak RAM, against the RAM of the server it ran on (nominal GB: MemTotal rounded up)."""
    measured = [u for u in us if u["peak_mb"] != "n/a"]
    if not measured:
        return "n/a"
    top = max(measured, key=lambda u: int(u["peak_mb"]))
    server = "?" if top["ram_mb"] == "n/a" else str(math.ceil(int(top["ram_mb"]) / 1024))
    return f"{int(top['peak_mb']) / 1024:.1f} / {server} GB"


def ram_wait(us):
    stalls = [int(u["stall_s"]) for u in us if u["stall_s"] != "n/a"]
    return f"{max(stalls)} s" if stalls else "n/a"


def cores_used(us):
    """Average cores used per run (CPU time / duration): typical (median) and highest, against that run's vCPUs."""
    runs = sorted(((int(u["cpu_s"]) / max(int(u["seconds"]), 1), u["vcpus"]) for u in us if u["cpu_s"] != "n/a"))
    if not runs:
        return "n/a"
    return f"{statistics.median(c for c, _ in runs):.1f} typ, {runs[-1][0]:.1f} max / {runs[-1][1]}"


def prune_logs(args):
    """prune-logs <logs dir> <keep_days>: deletes job logs (*.log) older than keep_days."""
    folder, cutoff = args[0], datetime.now().timestamp() - float(args[1]) * 86400
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        p = os.path.join(folder, name)
        if name.endswith(".log") and os.path.isfile(p) and os.path.getmtime(p) < cutoff:
            os.remove(p)


def find_prune(args):
    rules = Rules(args[0], args[1] if len(args) > 1 else "")
    names = [p for p in rules.ex if "/" not in p and not any(fnmatch.fnmatch(d.split("/")[-1], p) for d in rules.seed_dirs)]
    print(" ".join(f"-name {shlex.quote(n)} -prune -o" for n in names))


# ---------------------------------------------------------------- RunPod: GPU pods (docs/specs/0004)
# Only RunPod's REST API, through urllib. The key (RUNPOD_API_KEY, from cloudmule's .env) only goes in the
# Authorization header of requests to the API; it is never printed and never sent to a pod.
RP_API = "https://api.runpod.io/v2"
RP_GOOD = ("MEDIUM", "HIGH")      # availability worth recommending
RP_REAP_GRACE_MIN = 5             # a cloudmule pod up longer than RUNPOD_MAX_MINUTES + this is an orphan


class RunPodError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def rp_base():
    base = (os.environ.get("RUNPOD_API_BASE") or RP_API).rstrip("/")
    # the key goes wherever this points: RunPod itself, or a fake API on this computer (tests)
    if not (base.startswith("https://api.runpod.io/") or re.fullmatch(r"http://127\.0\.0\.1:\d+(/.*)?", base)):
        raise RunPodError(0, "RUNPOD_API_BASE must be https://api.runpod.io/… (or a test server on 127.0.0.1)")
    return base


def rp_message(raw):
    """The error message of an API answer (JSON or text), short."""
    try:
        j = json.loads(raw)
    except ValueError:
        return raw.strip()[:300] or "(no message)"
    if isinstance(j, list) and j and isinstance(j[0], dict):
        j = j[0]
    if isinstance(j, dict):
        for k in ("error", "message", "detail"):
            if j.get(k):
                return str(j[k])[:300]
    return str(j)[:300]


def rp(method, path, body=None):
    key = os.environ.get("RUNPOD_API_KEY", "").strip()
    if not key:
        raise RunPodError(0, "RUNPOD_API_KEY is missing in cloudmule's .env (the user pastes it there; see .env.example)")
    req = urllib.request.Request(rp_base() + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "Accept": "application/json", "User-Agent": "cloudmule"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        msg = rp_message(e.read().decode("utf-8", "replace"))
        if e.code == 401:
            msg = "the RunPod API refused the key (HTTP 401): check RUNPOD_API_KEY in cloudmule's .env"
        raise RunPodError(e.code, msg) from None
    except (urllib.error.URLError, OSError) as e:
        raise RunPodError(0, f"could not reach the RunPod API: {getattr(e, 'reason', e)}") from None
    return json.loads(raw) if raw.strip() else {}


def pod_cost(p, default=0.0):
    """A pod's price in USD/h as the API reports it."""
    return float(p.get("cost") or p.get("costPerHr") or default or 0)


def rp_list(data):
    """The list in an API answer (a bare list, or the first list value of an object)."""
    if isinstance(data, list):
        return data
    for v in (data or {}).values():
        if isinstance(v, list):
            return v
    return []


def rp_catalog(cloud):
    try:
        return rp_list(rp("GET", f"/catalog/gpus?include=AVAILABILITY&product=POD&cloud={cloud}"))
    except RunPodError as e:
        if e.status != 403:
            raise
        raise RunPodError(403, "RUNPOD_FORBIDDEN: the RunPod API key cannot read the GPU catalog (HTTP 403), so "
                               "cloudmule cannot see which GPUs are available now. Give the key \"catalog read\" "
                               "permission (runpod.io -> Settings -> API Keys), or create one that has it and paste "
                               "it into cloudmule's .env yourself.") from None


def usd(x):
    """A price in USD: 2 decimals, 3 when the third one matters (0.59, 0.165)."""
    s = f"{float(x):.3f}"
    return s[:-1] if s.endswith("0") else s


def gpu_price(g, cloud):
    p = g.get("price")
    v = p.get(cloud.lower()) if isinstance(p, dict) else None
    try:
        v = float(v) if v is not None else None
    except (TypeError, ValueError):
        return None
    return v if v and v > 0 else None   # RunPod lists GPUs it does not offer in that cloud at price 0


def gpu_avail(g, cloud):
    a = g.get("availability")
    if isinstance(a, dict):
        a = a.get(cloud.lower())
    return str(a or "NONE").upper()


class GpuLimits:
    """The caps from .env (hourly price, minutes per pod, what is left of today's budget) and the project's VRAM."""
    def __init__(self, o):
        self.vram = float(o.get("min-vram") or 0)
        self.needs = str(o.get("needs") or "")   # the project's NEEDS_GPU (graphics, cuda, or "" if unknown)
        self.max_usd = float(o["max-usd"])
        self.minutes = float(o["max-minutes"])
        self.day_left = float(o["day-left"])

    def worst(self, usd_h):
        """The most one pod can cost: it is deleted after max-minutes whatever happens."""
        return usd_h * self.minutes / 60


def gpu_eval(g, cloud, price, lim):
    """One catalog offer against the limits: reasons it cannot be used, as (kind, text), most basic first."""
    why = []
    if cloud == "COMMUNITY":
        why.append(("cloud", "no public SSH (community cloud)"))
    if "nvidia" not in f"{g.get('manufacturer') or ''} {g.get('id') or ''}".lower():
        why.append(("vendor", "not NVIDIA (pods run CUDA images)"))
    names = " ".join(str(g.get(k) or "") for k in ("id", "name", "displayName"))
    if lim.needs == "graphics" and re.search(r"\bMIG\b", names, re.I):
        why.append(("whole-gpu", "MIG slice: no Vulkan/OpenGL (graphics needs a whole GPU)"))
    vram = float(g.get("memory") or g.get("memoryInGb") or 0)
    if vram < lim.vram:
        why.append(("vram", f"VRAM < {gb(lim.vram)} GB"))
    if price > lim.max_usd:
        why.append(("hourly", f"above the hourly cap {usd(lim.max_usd)} USD/h"))
    elif lim.worst(price) > lim.day_left:
        why.append(("daily", f"worst case {usd(lim.worst(price))} USD passes today's cap ({usd(max(lim.day_left, 0))} left)"))
    avail = gpu_avail(g, cloud)
    if avail == "NONE":
        why.append(("unavailable", "none available now"))
    return {"id": str(g.get("id")), "cloud": cloud, "usd": price, "vram": vram, "avail": avail, "why": why}


def gpus_menu(o):
    lim = GpuLimits(o)
    rows = []
    for cloud in str(o.get("clouds") or "SECURE").split():
        for g in rp_catalog(cloud):
            price = gpu_price(g, cloud)
            if price is not None and g.get("id"):
                rows.append(gpu_eval(g, cloud, price, lim))
    rows.sort(key=lambda e: (bool(e["why"]), any(k == "unavailable" for k, _ in e["why"]), e["usd"], e["id"]))
    w = max([len(e["id"]) for e in rows] + [3])
    print(f"{'GPU':<{w}}  {'VRAM':>6}  {'CLOUD':<10}{'USD/H':>6}  {'MAX/POD':>7}  {'AVAIL':<7} VERDICT")
    for e in rows:
        last = " (last choice)" if (e["id"], e["cloud"]) == (o.get("last-gpu"), o.get("last-cloud")) else ""
        verdict = "no: " + texts(e["why"]) if e["why"] else "fits" + last
        print(f"{e['id']:<{w}}  {gb(e['vram']) + ' GB':>6}  {e['cloud']:<10}{usd(e['usd']):>6}  "
              f"{usd(lim.worst(e['usd'])):>7}  {e['avail']:<7} {verdict}")
    print(f"MAX/POD = USD/H x {gb(lim.minutes)} min (RUNPOD_MAX_MINUTES): the most one pod can cost.")
    fit = [e for e in rows if not e["why"]]
    print(f"{len(fit)} of {len(rows)} GPU offers fit right now.")
    rec = [e for e in fit if e["avail"] in RP_GOOD] or fit
    if rec:
        print(f"RECOMMENDED: {rec[0]['id']} {rec[0]['cloud']} {usd(rec[0]['usd'])}")
    else:
        print("RECOMMENDED: none (nothing available fits: try again later, or change the caps in cloudmule's .env "
              "or the project's MIN_VRAM_GB)")


def record_path(records, pid):
    return os.path.join(records, f"{pid}.json")


def read_records(records):
    out = []
    for name in sorted(os.listdir(records)) if os.path.isdir(records) else []:
        if name.endswith(".json"):
            try:
                with open(os.path.join(records, name), encoding="utf-8") as f:
                    out.append(json.load(f))
            except (OSError, ValueError):
                continue
    return out


def write_record(records, rec):
    os.makedirs(records, exist_ok=True)
    tmp = record_path(records, rec["id"]) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f)
    os.replace(tmp, record_path(records, rec["id"]))


def pod_usage_line(rec, billed_s, measure_file=""):
    """The usage line of a deleted pod: the job's measurement (if it ran) and what the pod cost."""
    m = {}
    if measure_file and os.path.exists(measure_file):
        with open(measure_file, encoding="utf-8") as f:
            for raw in f.read().splitlines():
                m = measurement(raw) or m
    seconds = str(int(m["end"]) - int(m["start"])) if m else str(billed_s)
    return ([datetime.now().strftime("%Y-%m-%dT%H:%M"), rec.get("project") or "-", rec.get("target") or "-",
             rec.get("job") or "-", rec.get("gpu") or "unknown", seconds] + measured_fields(m)
            + ["runpod", str(billed_s), f"{float(rec.get('cost') or 0) * billed_s / 3600:.4f}"])


def pod_delete(rec, o, measure_file="", billed_s=None):
    """Deletes a recorded pod (retrying: a pod left behind bills), records its usage line, forgets its record."""
    for attempt in range(3):
        try:
            rp("DELETE", f"/pods/{rec['id']}")
            break
        except RunPodError as e:
            if e.status == 404:
                break   # already gone
            if attempt == 2:
                raise RunPodError(e.status, f"could not delete pod {rec['id']} ({e}): IT IS STILL BILLING. Delete "
                                            f"it in the RunPod console (Pods) now.") from None
            time.sleep(5)
    if billed_s is None:
        billed_s = max(0, int(time.time() - float(rec.get("created") or time.time())))
    append_usage(o["usage"], float(o.get("keep-days") or 90), [pod_usage_line(rec, billed_s, measure_file)])
    try:
        os.remove(record_path(o["records"], rec["id"]))
    except OSError:
        pass
    return billed_s


def rp_launch(o):
    lim = GpuLimits(o)
    cloud = o["cloud"]
    if lim.day_left <= 0:
        fail_launch("DAILY_CAP_REACHED", ["today's GPU spend (with the pods running now) has reached "
                                          "RUNPOD_MAX_USD_PER_DAY"])
    gids = [c.strip() for c in str(o.get("candidates") or "").split(",") if c.strip()]
    if not gids:
        fail_launch("NEEDS_GPU_CHOICE", ["no GPU id given (see: cloudmule gpus)"])
    catalog = {str(g.get("id")): g for g in rp_catalog(cloud)}
    kinds, why = [], []
    for gid in gids:
        g = catalog.get(gid)
        price = gpu_price(g, cloud) if g else None
        if price is None:
            kinds.append("unknown")
            why.append(f"{gid}: not offered in RunPod's {cloud} catalog (see: cloudmule gpus)")
            continue
        e = gpu_eval(g, cloud, price, lim)
        if e["why"]:
            kinds.append(e["why"][0][0])
            why.append(f"{gid}: {texts(e['why'])}")
            continue
        if o.get("dry-run"):
            print(f"WOULD_CREATE: {gid} {cloud} {usd(price)} {usd(lim.worst(price))}")
            return
        with open(o["pubkey-file"], encoding="utf-8") as f:
            pub = f.read().strip()
        body = {"name": o["name"], "image": o["image"], "cloud": cloud, "gpu": {"id": gid, "count": 1},
                "disk": int(float(o["disk"])), "ports": ["22/tcp"],
                # the pod's image authorises PUBLIC_KEY for SSH; NVIDIA_DRIVER_CAPABILITIES=all mounts the graphics
                # libraries too (Vulkan/EGL), not only the compute ones
                # CLOUDMULE_MAX_MINUTES: this pod's own time cap, so any computer's orphan check uses it
                "env": {"PUBLIC_KEY": pub, "SSH_PUBLIC_KEY": pub, "NVIDIA_DRIVER_CAPABILITIES": "all",
                        "CLOUDMULE_MAX_MINUTES": f"{lim.minutes:g}"}}
        progress(f"Creating a GPU pod: {gid}, {cloud}, about {usd(price)} USD/h…")
        new = {"name": o["name"], "gpu": gid, "cloud": cloud, "run": o["run"], "project": o.get("project") or "-",
               "target": o.get("target") or "-", "job": o.get("job") or "-"}
        try:
            pod = rp("POST", "/pods", body)
        except RunPodError as err:
            if err.status == 400:   # what RunPod answers when no such GPU is free now
                kinds.append("unavailable")
                why.append(f"{gid}: not created ({err})")
                progress(f"  {gid}: not created ({err})")
                continue
            # anything else (network, 5xx, timeout): the pod may exist anyway. Delete it if it does, then stop.
            raise RunPodError(err.status, f"creating the pod failed ({err}); {cleanup_strays(o, new, price)}") from None
        if not pod.get("id"):
            raise RunPodError(0, f"RunPod answered without a pod id; {cleanup_strays(o, new, price)}")
        cost = pod_cost(pod, price)
        rec = dict(new, id=str(pod["id"]), cost=cost, created=time.time(), max_minutes=lim.minutes)
        write_record(o["records"], rec)   # first thing: from now on every cleanup path knows this pod
        over = None
        if cost > lim.max_usd:
            over = ("hourly", f"above the hourly cap {usd(lim.max_usd)} USD/h")
        elif lim.worst(cost) > lim.day_left:   # the catalog price passed, the real one may not
            over = ("daily", f"worst case {usd(lim.worst(cost))} USD passes today's cap")
        if over:
            progress(f"  {gid}: RunPod charges {usd(cost)} USD/h, {over[1]}: deleting it at once.")
            pod_delete(rec, o)
            kinds.append(over[0])
            why.append(f"{gid}: created at {usd(cost)} USD/h, {over[1]}: deleted")
            continue
        print(f"POD\t{rec['id']}\t{usd(cost)}\t{gid}")
        return
    # one code for the whole refusal: the shared reason when every candidate had the same one; otherwise
    # NO_FITTING_GPU if some candidate can never fit (VRAM, vendor, cloud, unknown id), else NO_GPU_AVAILABLE
    single = {"hourly": "ABOVE_HOURLY_CAP", "daily": "DAILY_CAP_REACHED", "unavailable": "NO_GPU_AVAILABLE"}
    if len(set(kinds)) == 1 and kinds[0] in single:
        code = single[kinds[0]]
    elif set(kinds) - set(single):
        code = "NO_FITTING_GPU"
    else:
        code = "NO_GPU_AVAILABLE"
    fail_launch(code, why)


def cleanup_strays(o, new, price):
    """After a failed create: deletes any pod with this run's name (it may have been created after all)."""
    try:
        strays = [p for p in rp_list(rp("GET", "/pods")) if p.get("name") == new["name"]]
    except RunPodError as e:
        return (f"could not check whether a pod was created ({e}): run 'cloudmule status' and delete any "
                f"{new['name']} pod in the RunPod console")
    for p in strays:
        rec = dict(new, id=str(p.get("id")), cost=pod_cost(p, price), created=time.time())
        write_record(o["records"], rec)
        pod_delete(rec, o)
    return f"{len(strays)} pod(s) created anyway were deleted" if strays else "no pod was created"


def fail_launch(code, why):
    sys.stderr.write(f"{code}: {' | '.join(why)} (no pod is running for this command)\n")
    sys.exit(3)


def progress(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def rp_wait(pid, o):
    """Waits until the pod runs with a public SSH port: prints "ip port"."""
    timeout, every = float(o["timeout"]), float(o["interval"])
    t0, status = time.time(), "unknown"
    while True:
        try:
            p = rp("GET", f"/pods/{pid}")
            status = str(p.get("desiredStatus") or p.get("status") or status)
            for port in (p.get("runtime") or {}).get("ports") or []:
                if str(port.get("private")) == "22" and port.get("public") and port.get("ip"):
                    print(f"{port['ip']} {port['public']}")
                    return
        except RunPodError as e:
            if e.status == 404:
                status = "gone"
                break
            if e.status in (401, 403):
                raise
            # anything else (network, a 5xx) may pass: keep waiting
        if time.time() - t0 >= timeout:
            break
        time.sleep(every)
    sys.stderr.write(f"NO_PUBLIC_SSH: the pod has no public SSH port after {int(time.time() - t0)} s (status "
                     f"{status}); it is deleted now.\n")
    sys.exit(4)


def rp_delete_run(o):
    """Deletes every pod this computer recorded for the run; prints what each cost."""
    for rec in [r for r in read_records(o["records"]) if r.get("run") == o["run"]]:
        billed = pod_delete(rec, o, o.get("measure") or "")
        cost = float(rec.get("cost") or 0)
        print(f"GPU pod {rec['id']} deleted: {rec.get('gpu')}, {usd(cost)} USD/h, up {billed / 60:.1f} min, "
              f"about {usd(cost * billed / 3600)} USD (estimate; RunPod's billing is authoritative).")


def pod_age_min(p, rec):
    """Minutes since the pod was created: from this computer's record, else from the API's fields; None if unknown."""
    if rec and rec.get("created"):
        return (time.time() - float(rec["created"])) / 60
    for k in ("createdAt", "created_at"):
        v = p.get(k)
        if isinstance(v, str) and v:
            try:
                t = datetime.fromisoformat(re.sub(r"(\.\d+)?Z$", "+00:00", v.replace(" UTC", "Z")))
                if t.tzinfo is None:
                    t = t.replace(tzinfo=timezone.utc)
                return (datetime.now(timezone.utc) - t).total_seconds() / 60
            except ValueError:
                continue
    up = (p.get("runtime") or {}).get("uptimeInSeconds")
    return float(up) / 60 if isinstance(up, (int, float)) else None


def pod_gpu(p, rec):
    g = p.get("gpu")
    if isinstance(g, dict):
        g = g.get("id") or g.get("displayName")
    return str(g or p.get("gpuTypeId") or (rec or {}).get("gpu") or "?")


def pod_cap(p, rec, default):
    """A pod's own time cap in minutes: the CLOUDMULE_MAX_MINUTES it was created with (its env, as RunPod lists it,
    or this computer's record), else this computer's cap."""
    env = p.get("env")
    if isinstance(env, list):   # ["K=V", …] or [{"key": K, "value": V}, …]
        env = dict(e.split("=", 1) if isinstance(e, str) and "=" in e else
                   (e.get("key"), e.get("value")) if isinstance(e, dict) else ("", "") for e in env)
    for v in ((env or {}).get("CLOUDMULE_MAX_MINUTES") if isinstance(env, dict) else None,
              (rec or {}).get("max_minutes")):
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        if math.isfinite(v) and v > 0:   # a broken value must neither keep a pod forever nor reap it at once
            return v
    return default


def rp_pods(o):
    """The account's pods. cloudmule's (named cloudmule-*) older than max-minutes + 5 are orphans: deleted. A pod
    that could not be deleted is still listed, and the command then fails (exit 2)."""
    own = float(o["max-minutes"])
    recs = {r["id"]: r for r in read_records(o["records"])}
    pods = rp_list(rp("GET", "/pods"))
    seen, lines, worst, failed = set(), [], 0.0, []
    for p in pods:
        pid, name = str(p.get("id") or ""), str(p.get("name") or "")
        seen.add(pid)
        mine = name.startswith("cloudmule-")
        rec = recs.get(pid)
        age = pod_age_min(p, rec)
        if age is None and mine:
            # no age anywhere: remember when this computer first saw it, so it is reaped after the limit from then
            rec = {"id": pid, "name": name, "gpu": pod_gpu(p, None), "cost": pod_cost(p), "created": time.time(),
                   "first_seen": True, "run": "", "project": "-", "target": "-", "job": name}
            write_record(o["records"], rec)
            age = 0.0
        cost = pod_cost(p, (rec or {}).get("cost"))
        cap = pod_cap(p, rec, own)   # another computer may have created it with a longer cap
        if mine and o.get("reap") and age is not None and age > cap + RP_REAP_GRACE_MIN:
            try:
                # a pod no record of this computer knows (another computer's, or a lost record): job = its name
                pod_delete(rec or {"id": pid, "gpu": pod_gpu(p, rec), "cost": cost,
                                   "created": time.time() - age * 60, "job": name}, o)
                print(f"ORPHAN_DELETED: {name} ({pid}), {pod_gpu(p, rec)}, up {age:.0f} min (past its "
                      f"{cap:g} min cap + {RP_REAP_GRACE_MIN})")
                continue
            except RunPodError as e:
                failed.append(str(e))
        if age is None:
            up = "up ? min"
        elif (rec or {}).get("first_seen"):
            up = f"up ? min (RunPod gives no age; first seen {age:.0f} min ago)"
        else:
            up = f"up {age:.0f} min"
        if mine:
            worst += cost * cap / 60
            lines.append(f"  {name} ({pid}): {pod_gpu(p, rec)}, {usd(cost)} USD/h, {up}")
        else:
            lines.append(f"  WARNING: {name or '(no name)'} ({pid}) is not cloudmule's: {pod_gpu(p, rec)}, "
                         f"{usd(cost)} USD/h, {up}. It bills too (RunPod console -> Pods).")
    # records of pods that no longer exist (deleted elsewhere): count them as billed for their whole time limit
    for pid, rec in recs.items():
        cap = pod_cap({}, rec, own)
        if pid not in seen and time.time() - float(rec.get("created") or 0) > (cap + RP_REAP_GRACE_MIN) * 60:
            pod_delete(rec, o, billed_s=int(min(time.time() - float(rec.get("created") or 0), cap * 60)))
    if o.get("worst"):
        print(f"RUNNING_WORST_USD {worst:.4f}")
    else:
        print("\n".join(lines) if lines else "  none")
    if failed:
        raise RunPodError(0, " | ".join(failed))


def is_pod(u):
    """A usage line of a RunPod GPU pod (the others are jobs on the Hetzner server)."""
    return u["provider"] == "runpod"


def of_today(rows):
    today = datetime.now().strftime("%Y-%m-%d")
    return [u for u in rows if u["date"].startswith(today)]


def rp_spend(path):
    """Today's GPU spend in USD, from the usage lines of deleted pods."""
    total = sum(float(u["cost_usd"]) for u in of_today(read_usage(path, 3650, prune=False))
                if is_pod(u) and u["cost_usd"] != "n/a")
    print(f"{total:.4f}")


def runpod_main(cmd, args):
    o = opts(args)
    try:
        if cmd == "rp-gpus":
            gpus_menu(o)
        elif cmd == "rp-launch":
            rp_launch(o)
        elif cmd == "rp-wait":
            rp_wait(args[0], o)
        elif cmd == "rp-delete":
            rp_delete_run(o)
        elif cmd == "rp-reap":
            time.sleep(float(o["after"]))
            rp_delete_run(o)
        elif cmd == "rp-pods":
            rp_pods(o)
        else:
            sys.exit(f"unknown command {cmd}")
    except RunPodError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        sys.exit(5 if e.status == 403 else 2)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8")
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "rp-spend":
        return rp_spend(args[0])
    if cmd.startswith("rp-"):
        return runpod_main(cmd, args)
    if cmd == "sync-plan":
        return sync_plan(args)
    if cmd == "find-prune":
        return find_prune(args)
    if cmd == "guide":
        return print(GUIDE)
    if cmd == "usage-add":
        return usage_add(args)
    if cmd == "usage":
        return usage_report(args)
    if cmd == "prune-logs":
        return prune_logs(args)
    data = json.load(sys.stdin)
    if cmd == "menu":
        menu(data, opts(args))
    elif cmd == "candidates":
        candidates(data, opts(args))
    elif cmd == "below":
        print(texts(fit_reasons(data["server_type"], Reqs(opts(args)))))
    elif cmd == "server-type":
        t = data["server_type"]
        print(f"{t['name']}, {t['cores']} vCPU / {gb(t['memory'])} GB / {t['disk']} GB {t['cpu_type']}")
    elif cmd == "choice":
        print(choice(data, args[0] if args else ""))
    elif cmd == "server-disk":
        print(f"{data['server_type']['disk']} {data['server_type']['architecture']}")
    elif cmd == "image-info":
        print(f"{int(float(data['disk_size']))} {data['architecture']}")
    elif cmd == "field":
        print(data[args[0]])
    elif cmd == "label":
        print((data.get("labels") or {}).get(args[0], ""))
    elif cmd == "overdue":
        for s in data:
            if age_h(s["created"]) > float(args[0]):
                print(s["name"])
    elif cmd == "ages":
        for s in data:
            h = age_h(s["created"])
            print(f"  {s['name']} ({s['server_type']['name']}): {s['status']}, up for {h:.2f} h "
                  f"(Hetzner bills started hours: {int(h) + 1} h)")
    else:
        sys.exit(f"unknown command {cmd}")


main()
