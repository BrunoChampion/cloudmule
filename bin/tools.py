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
"""
import fnmatch
import json
import math
import os
import shlex
import statistics
import sys
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
                "stall_s")    # time its tasks stalled for lack of memory (memory.pressure "some")
NUMERIC = ("seconds", "peak_mb", "ram_mb", "cpu_s", "vcpus", "exit", "stall_s")


def usage_line_ok(u):
    return all(u[k] == "n/a" or u[k].lstrip("-").isdigit() for k in NUMERIC)


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
        u = dict(zip(USAGE_FIELDS, line.split("\t")))
        if len(u) != len(USAGE_FIELDS) or not usage_line_ok(u):
            continue   # not a usage line (hand-edited, or an older format): ignored, kept in the file
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
        m = dict(kv.split("=", 1) for kv in raw.split() if "=" in kv)
        if not (m.get("start", "").isdigit() and m.get("end", "").isdigit()):
            continue
        end = int(m["end"])
        out.append([datetime.fromtimestamp(end).strftime("%Y-%m-%dT%H:%M"), project, target, job,
                    m.get("type") or "unknown", str(end - int(m["start"])), scaled(m.get("peak_bytes", ""), 1048576),
                    scaled(m.get("mem_kb", ""), 1024), scaled(m.get("cpu_usec", ""), 1000000),
                    m.get("vcpus") or "n/a", m.get("exit") or "n/a", scaled(m.get("stall_usec", ""), 1000000)])
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
    cores used, longest run, server types."""
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
    print(f"{'PROJECT':<12}{'JOB':<18}{'RUNS':>5}  {'PEAK RAM':<15}{'RAM WAIT':<10}{'CORES USED':<24}{'LONGEST':<9}TYPES")
    for (p, j), us in sorted(jobs.items()):
        longest = f"{max(int(u['seconds']) for u in us) / 60:.0f} min"
        types = " ".join(sorted({u["type"] for u in us}))
        print(f"{p:<12}{j:<18}{len(us):>5}  {peak_ram(us):<15}{ram_wait(us):<10}{cores_used(us):<24}{longest:<9}{types}")
    measured = [u for u in rows if u["peak_mb"] != "n/a"]
    if measured:
        top = max(measured, key=lambda u: int(u["peak_mb"]))
        where = " ".join(x for x in (top["project"], top["target"], top["job"]) if x != "-")
        print(f"Highest peak RAM: {int(top['peak_mb']) / 1024:.1f} GB ({where}).")
    print("PEAK RAM includes file cache the kernel frees when needed; RAM WAIT is how long the job stalled for lack")
    print("of memory: near 0 s means the RAM was enough. Jobs that run at the same time on the shared server add up.")


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


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8")
    cmd, args = sys.argv[1], sys.argv[2:]
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
