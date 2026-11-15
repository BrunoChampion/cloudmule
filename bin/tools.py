"""Helpers for bin/cloudmule (run with `python -I`).

JSON from `hcloud … -o json` on stdin:
  menu [requirements] [--running <type>]   server types table for the user: fit verdict + reason, price, location;
                                      last line "RECOMMENDED: <type> <location> <eur/h>" (or "RECOMMENDED: none")
  candidates --types "<t…>" [requirements]  fitting (type, location, EUR/h) in the given order, cheapest available
                                      location first; none fits -> "NO_FITTING_SERVER: <reasons>" on stderr, exit 3
  below [requirements]                a server (describe JSON): why it is below the requirements (empty if not)
  image-info                          an image (describe JSON): "<disk_size GB> <architecture>"
  server-type                         a server (describe JSON): "<type>, <vCPU> / <RAM> / <disk> <cpu kind>"
  requirements: --locations "<l…>" --min-ram <GB> --min-cpus <n> --min-disk <GB> --archs "<x86 arm>"
                --workspace-disk <GB> --workspace-arch <x86|arm>   (a snapshot restores only on a disk >= its own)
  price "<locations>"                 hourly gross price of one server type per location
  field <name> | label <key>          one field / one label of a JSON object
  ages                                servers: name, status, hours up, hours billed
  overdue <hours>                     names of servers older than <hours>

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
import os
import shlex
import sys
from datetime import datetime, timezone


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


def fit_reasons(t, r):
    """Why server type t does not meet the requirements (hardware + saved workspace), ignoring availability."""
    why = []
    if float(t["memory"]) < r.ram:
        why.append(f"ram < {gb(r.ram)} GB")
    if int(t["cores"]) < r.cpus:
        why.append(f"cpus < {r.cpus}")
    if int(t["disk"]) < r.disk:
        why.append(f"disk < {r.disk} GB")
    if t["architecture"] not in r.archs:
        why.append(f"arch {t['architecture']} (project needs {'/'.join(r.archs) or 'nothing available'})")
    if r.ws_disk and int(t["disk"]) < r.ws_disk:
        why.append(f"workspace needs disk >= {r.ws_disk} GB (or --fresh)")
    if r.ws_arch and t["architecture"] != r.ws_arch:
        why.append(f"workspace is {r.ws_arch} (or --fresh)")
    return why


def evaluate(t, r):
    price = {p["location"]: float(p["price_hourly"]["gross"]) for p in t.get("prices", []) if p["location"] in r.locs}
    avail = sorted((l["name"] for l in t.get("locations", []) if l.get("available") and l["name"] in price),
                   key=lambda l: price[l])
    why = fit_reasons(t, r) + ([] if avail else ["unavailable"])
    best = avail[0] if avail else (min(price, key=price.get) if price else "")
    return {"t": t, "price": price, "avail": avail, "why": why, "best": best}


def menu(data, o):
    r = Reqs(o)
    rows = [evaluate(t, r) for t in data if not t.get("deprecated")]
    rows = [e for e in rows if e["price"]]   # offered in at least one allowed location
    rows.sort(key=lambda e: (bool(e["why"]), "unavailable" in e["why"], e["price"][e["best"]]))
    print(f"{'TYPE':<8}{'VCPU':>5}{'RAM':>8}{'DISK':>9}  {'CPU':<10}{'ARCH':<6}{'LOCATION':<10}{'EUR/H':>8}  VERDICT")
    for e in rows:
        t = e["t"]
        verdict = "fits" if not e["why"] else "no: " + "; ".join(e["why"])
        loc = e["best"] if e["avail"] else "-"
        print(f"{t['name']:<8}{t['cores']:>5}{gb(t['memory']) + ' GB':>8}{str(t['disk']) + ' GB':>9}  "
              f"{t['cpu_type']:<10}{t['architecture']:<6}{loc:<10}{e['price'][e['best']]:>8.4f}  {verdict}")
    print("CPU: shared = cheaper, speed varies with neighbours' load; dedicated = full cores, steadier for long "
          "CPU-bound work (renders, big builds). Prices include VAT, per started hour.")
    fit = [e for e in rows if not e["why"]]
    print(f"{len(fit)} of {len(rows)} server types fit this project right now.")
    if fit:
        e = fit[0]
        print(f"RECOMMENDED: {e['t']['name']} {e['best']} {e['price'][e['best']]:.4f}")
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
            why.append(f"{name}: " + "; ".join(e["why"]))
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
    data = json.load(sys.stdin)
    if cmd == "menu":
        menu(data, opts(args))
    elif cmd == "candidates":
        candidates(data, opts(args))
    elif cmd == "below":
        print("; ".join(fit_reasons(data["server_type"], Reqs(opts(args)))))
    elif cmd == "server-type":
        t = data["server_type"]
        print(f"{t['name']}, {t['cores']} vCPU / {gb(t['memory'])} GB / {t['disk']} GB {t['cpu_type']}")
    elif cmd == "image-info":
        print(f"{int(float(data['disk_size']))} {data['architecture']}")
    elif cmd == "price":
        locs = set(args[0].split()) if args else set()
        for p in data.get("prices", []):
            if not locs or p["location"] in locs:
                print(f"  {data['name']} in {p['location']}: {float(p['price_hourly']['gross']):.4f} EUR/h incl. VAT "
                      f"({data['cores']} vCPU, {data['memory']:.0f} GB RAM, {data['disk']} GB disk)")
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
