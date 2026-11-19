# cloudmule

cloudmule runs the heavy work of the user's projects (dependency installs, builds, tests, dev servers, test
browsers, renders) on ONE Hetzner Cloud server rented by the hour and shared by all their projects. Their
computer only edits. The cycle: **create or join the server → upload only what changed → run jobs → download
results → release the lease → when nobody uses it: snapshot and DELETE the server.**

Work that needs a **GPU** (WebGL/three.js rendering in headless Chrome, CUDA) goes to **RunPod** instead: one GPU
pod per job, never shared: **create → set up → upload → run → download → DELETE** (docs/specs/0004).

Talk to the user in their language. This file is for agents; humans read `README.md`.

## Installing cloudmule (when the user asks for it in this folder)

Do it step by step, explaining each one in plain words, and stop at anything that fails.

1. **Requirements.** Check `bash --version` (Windows: Git Bash), `python3 --version` or `python --version`,
   `ssh -V`, `hcloud version`. If `hcloud` (Hetzner's official CLI) is missing, offer to install it, with the
   user's permission: Windows `winget install --id HetznerCloud.CLI --exact --source winget`, macOS
   `brew install hcloud`, Linux: the release binary from github.com/hetznercloud/cli, verifying its SHA256
   against the release's `checksums.txt`.
2. **Hetzner account and token.** If the user has none: create an account at hetzner.com/cloud, create a
   project (a dedicated one for cloudmule is best), then Security → API tokens → Generate, **Read & Write**.
   Then `cp .env.example .env` and ask the user to paste the token into `.env` **themselves**. Never ask for it in
   the chat, never print it.
3. `bash bin/cloudmule setup`: checks the token, creates this computer's SSH key and registers it
   in Hetzner, saves this folder's location in `~/.config/cloudmule/home` and installs the Claude Code plugin
   (the `cloudmule` skill). Tell the user the skill appears in **new** Claude Code sessions.
4. Optional, for work that needs a GPU: a RunPod account with credit, and an API key (RunPod → Settings → API
   Keys) that can manage pods and has **catalog read** permission. The user pastes it into `.env`
   (`RUNPOD_API_KEY`) **themselves**, and checks the caps below it (`RUNPOD_MAX_USD_PER_HOUR`,
   `RUNPOD_MAX_MINUTES`, `RUNPOD_MAX_USD_PER_DAY`). `bash bin/cloudmule gpus` checks the key.
5. Done. Explain the next step: in any project, ask for heavy work ("run the tests") or say "set up cloudmule
   here". There is no image to build: the first `start` installs what each project needs (it takes a few
   minutes longer, once).

## Rules (mandatory)

- **Spending money needs the user's choice and confirmation.** Before `start` or `oneshot` creates a server,
  show the user the options from `servers <project>` (free), with their last choice, recommend one, and wait for
  their choice; then `start … --type <chosen>` (or `oneshot … --type <chosen> <job>`). No setting picks a type:
  creating without `--type` is refused. Joining a running server needs no new choice. With a session open, `sync`,
  `job`, `attach`, `pull`, `run` and `tunnel` need no new confirmation; neither do `servers`, `status`, `leases`,
  `projects`, `init`, `setup`, `end`, `usage`, `gpus`, `start --dry-run` and `gpu --dry-run`.
- **Report the server type and price** used (the "Creating … EUR/h" line).
- **GPU pods (RunPod) need the same choice and confirmation:** `gpus <project>` (free) shows the options, the
  caps and today's spend; recommend one, wait for the user's yes, then `gpu … --approved --gpu <id> <job>`.
  `--approved` means the user said yes to this pod. Only with `RUNPOD_STANDING_APPROVAL=1` in `.env` may pods be
  created without asking, and the skill writes it **only when the user explicitly grants it** (with the caps they
  give; reading them back and saying how to revoke). The caps in `.env` (USD/h, minutes per pod, USD per day, USD
  per month, optional pods at once) are enforced by cloudmule in every case and cannot be raised from the
  environment. Read the `RUNNING_PODS` lines `gpu` prints (other sessions' pods). After each GPU job report GPU,
  USD/h, minutes, cost and the `GPU_USE` line, then `status`.
- **A graphics render is not finished on `GPU_OK` alone** when the project has no `GPU_SELFTEST`: say so to the user.
  `GPU_DEGRADED`/`GPU_TIME_CAP` results are downloaded for inspection only. Fill one GPU with parallel tasks
  (`cloudmule-par`, slots chosen from `GPU_USE`) before proposing more pods or a pricier GPU (skill, section 5a).
- **CPU-only work never goes to RunPod.** A project's `NEEDS_GPU` says what it needs; if it is not set and the
  task may need a GPU, ask the user (and offer to write the answer into `config.sh`).
- **When done: `end <project> [target] --keep`, then `status`.** `end` releases your project's lease and only
  deletes the server if no other project holds one. Don't leave leases behind "just in case".
- **Other sessions share the server** (other projects, other Claude sessions, other computers of the same user).
  Never delete it while other leases exist:
  1. `leases` shows each lease (project, target, computer, minutes since last use) and the running jobs.
  2. If `end` answers `OTHER_PROJECTS_USING_THE_SERVER`, leave the server on and tell the user.
  3. A lease that looks abandoned (long unused, 0 jobs running): ask the user (or that project's session)
     before `end … --force`.
  4. Don't worry about forgotten leases: with no activity the guard snapshots and deletes the server after
     `IDLE_MINUTES` (45). Forcing only saves that wait.
  5. When `start` shows other projects' leases, tell the user they share CPU and RAM.
- **Token and key:** only in `.env` (`HCLOUD_TOKEN`, `RUNPOD_API_KEY`), pasted by the user. Never print them,
  never use `set -x`. On the Hetzner server the token lives only in `/run/cloudmule/token` (RAM), so it never ends
  up in a snapshot. The RunPod key is never sent to a pod (the in-pod guard uses the pod's own credentials).
- **Never put secrets in a project's `.cloudmule/`**: it may be committed, even to a public repository.
  cloudmule refuses to run if it finds files that look like secrets there.
- **Don't restart on your own** a job the system or the user stopped. Report it and ask.
- **Before uploading a user's project for the first time**, remind them it will be stored on a third-party
  server (Hetzner) and in snapshots in their account; for a GPU job, on a RunPod pod (deleted with the pod).
- **Only Hetzner's official `hcloud` CLI and RunPod's REST API** (called from `bin/tools.py`). No community MCP
  servers, tools or the RunPod plugin: they would hold a token able to spend money.

## Commands

Run from any folder: `bash <cloudmule-folder>/bin/cloudmule …` (the skill finds the folder in
`~/.config/cloudmule/home`). `bash bin/cloudmule help` prints the same list.

| Command | What it does | Bills? |
|---|---|---|
| `setup` | Once per computer: token check, SSH key, location file, Claude Code plugin | No |
| `init [folder] [--name n] [--local]` | Sets up a project (creates `.cloudmule/` from `template/`) or registers one that already has it | No |
| `projects` | Projects registered on this computer and their folders | No |
| `servers [proj] [target] [--fresh]` | With no server running, a "How to choose" guide first. Then the disk floor, and the server types available now: vCPU, RAM, disk, CPU kind, architecture, cheapest location, €/h, whether each fits the project (and why not) and what it would do to the disk floor. A `Cheaper with --fresh` line when the disk floor shuts out a cheaper type. The user's `Last choice:` (from Hetzner labels; its row is marked). Last line `RECOMMENDED: <type> <location> <eur/h>` | No |
| `start <proj> [target] [--type t] [--location l] [--fresh] [--dry-run]` | Joins the server (prints its type and who chose it; `SERVER_BELOW_REQUIREMENTS` if it is smaller than the project needs) or creates it with the chosen type (`--type` required to create: `NEEDS_SERVER_TYPE` otherwise; recorded as the last choice) from the workspace snapshot (or plain Ubuntu), installs missing modules, runs `server-setup.sh`, syncs, installs dependencies, takes a lease. `--fresh`: ignore the saved workspace. `--dry-run`: print `WOULD_CREATE: <type> <location> <image> <eur/h>` and `WOULD_LABEL: …` (or `WOULD_JOIN`) and stop | **Yes, if it creates it** |
| `sync <proj> [target] [--with-generated]` | Uploads only what changed and deletes there what was deleted here | — |
| `job <proj> [target] <job> [args…]` | Syncs, runs `.cloudmule/jobs/<job>.sh` on the server and **downloads its results** | — |
| `attach <proj> [target] <job>` | Follows a job still running there and downloads its results | — |
| `pull <proj> [target] <path>…` | Downloads files or folders | — |
| `run <proj> [target] ['cmd']` | A command in the project's remote folder, or an interactive shell | — |
| `tunnel <proj> [target] <port>` | `http://localhost:<port>` here reaches `127.0.0.1:<port>` on the server (to look at something a job serves, without exposing it). Ctrl+C closes it; while open it counts as activity | — |
| `end <proj> [target] [--keep] [--forget] [--force]` | Releases the lease. If no other remains: (`--keep` → workspace snapshot) and deletes the server. `--forget`: deletes the project's folder on the server. `--force`: deletes even with other leases (only with confirmation) | Stops billing |
| `oneshot <proj> [target] [--type t] [--location l] <job> [args…]` | One job: uses the server if it is on; otherwise creates it (`--type` required) and deletes it at the end if nobody else uses it (also on failure) | Yes, if it creates it |
| `leases` | Who is using the server, since when, which jobs run | No |
| `status` | Servers (billed hours), leases, snapshots and RunPod pods (id, GPU, USD/h, minutes up; a warning for pods that are not cloudmule's). Deletes cloudmule pods up longer than `RUNPOD_MAX_MINUTES` + 5 (`ORPHAN_DELETED`). RunPod first, so a Hetzner error cannot hide a pod. `RUNPOD_UNKNOWN` (and exit 1) when it could not check every pod: not all clear, look in the RunPod console | No |
| `usage [proj] [target] [--month\|--phases]` | Per project and job: runs, highest peak RAM, RAM wait (stalled for lack of memory), typical and highest cores used, longest run, GPU cost (USD and minutes of its pods), server types or GPUs (from `logs/usage.tsv`; works without a token). Then the GPU spend: total, this month, today. `--month`: this month's GPU spend by project; `--phases`: each GPU run's `PHASES` and `GPU_USE` | No |
| `gpus [proj] [target] [--cloud secure\|community\|all] [--all]` | The caps, today's and this month's GPU spend and what is left (`MONTHLY_CAP_NEAR` at 80 %), the standing approval, then the GPUs RunPod has now that fit (`--all`: every offer and why not): VRAM, vCPU and RAM of its pods (catalog), cloud, USD/h, MAX/POD (worst case: USD/h × `RUNPOD_MAX_MINUTES`), availability, whether each fits (VRAM, NVIDIA, caps, SECURE: COMMUNITY pods have no public SSH; for `graphics` a whole GPU: MIG slices have no Vulkan/OpenGL; price 0 = not offered, left out) and why not. `Last choice:` (`logs/last-gpu`; its row is marked). Last line `RECOMMENDED: <gpu id> <cloud> <usd/h>`: the cheapest fitting GPU with MEDIUM/HIGH availability, else the cheapest fitting. `RUNPOD_FORBIDDEN` if the key lacks "catalog read". Writes the catalog cache (`logs/runpod-catalog.json`, 10 min) that `gpu` reads prices from. Deletes orphan pods like `status` | No |
| `gpu <proj> [target] --gpu <id[,id…]> [--cloud secure] [--approved] [--max-minutes n] [--wait-for-pod m] [--dry-run] <job> [args…]` | One job on a RunPod GPU pod (steps in "How it works"): prints `RUNNING_PODS: <n>` and the cloudmule pods already running (any session or computer), downloads the job's `CLOUDMULE_RESULT` paths (also when it fails), prints `GPU_USE …` (GPU, VRAM, CPU of the pod's allotment, RAM) with a `GPU_USE_HINT`, `PHASES …`, and `GPU_OK: <job>`, or `GPU_DEGRADED: <reason>` / `GPU_TIME_CAP` (exit ≠ 0, results downloaded for inspection), `NEAR_TIME_CAP` when it ended within 15 % of its cap; deletes the pod (also on failure): `GPU pod … deleted: <gpu>, <usd/h>, up <min>, about <usd>`. `--max-minutes` lowers this pod's cap (never raises it); `--wait-for-pod` waits for a slot under `RUNPOD_MAX_PODS`. Refusals before anything is created: `NEEDS_GPU_CHOICE`, `NEEDS_APPROVAL`, `NEEDS_GPU_UNSET`, `NO_GPU_NEEDED`, `GPU_SELFTEST_MISSING`, `ABOVE_TIME_CAP`, `TOO_MANY_PODS`, `LAUNCH_LOCK_TIMEOUT`, `ABOVE_HOURLY_CAP`, `DAILY_CAP_REACHED`, `MONTHLY_CAP_REACHED`, `NO_GPU_AVAILABLE`, `NO_FITTING_GPU`; after creation (the pod is deleted at once): `NO_PUBLIC_SSH`, `GPU_NOT_USED`, `GPU_CONTEXT_LOST`, `GPU_SELFTEST_FAILED`. `--dry-run`: `WOULD_CREATE: <gpu> <cloud> <usd/h> <max usd>` | **Yes** |
| `gpu-logs [<run tag>\|<pod id>] [-f]` | A running pod's job log (its tail) and its GPU/VRAM/CPU/RAM use now (`NOW …`); `-f` follows it. This computer's newest running pod by default (its SSH key stays here until the pod is deleted) | No |

`[target]` only exists for projects with `NEEDS_TARGET=1` (one sub-folder per piece of work, e.g. per video);
on the server each target lives in `/root/work/<project>/<target>`.

## A project's settings (`<project>/.cloudmule/`)

```
<project>/.cloudmule/
├── config.sh          ← PROJECT_NAME, LOCAL_DIR/REMOTE_DIR, MODULES, SYNC_EXCLUDE/SEEDS, INSTALL_* (no secrets)
├── jobs/<job>.sh      ← one script per heavy task; runs ON the server in REMOTE_DIR
├── server-setup.sh    ← optional: system tools only this project needs (once per server)
└── CLAUDE.md          ← optional: notes for agents (jobs, reference numbers, known problems)
```

- `config.sh` is sourced by bash with `$PROJECT_ROOT` (the project's folder) and `$TARGET` set. See
  `template/config.sh` for every setting.
- `MODULES` lists what the server needs (`remote/modules/<m>.sh`); `base` is always installed. Versioned
  modules (`node@24.15.0`) install into `/opt/<module>/<version>` so several versions coexist; each project's
  jobs, installs and `run` get its versions first on `PATH`.
- Jobs exit non-zero on failure and print `CLOUDMULE_RESULT <path relative to the project>` for every file or
  folder to download (paths without spaces).
- `<LOCAL_DIR>/.cloudmuleignore` adds sync exclusions, one pattern per line.
- `MIN_RAM_GB`, `MIN_CPUS`, `MIN_DISK_GB` (defaults 4 / 2 / 40) say what server the project needs; the
  architecture comes from its modules (each module declares `# arch: x86 arm`; ffmpeg is x86 only). A project never
  picks the server type: the user does, for the shared server (an old `SERVER_TYPES` is ignored with a note).
- `NEEDS_GPU` (`0`, `graphics`, `cuda`; not set = the project has not said: ask the user), `MIN_VRAM_GB`
  (default 8) and optional `RUNPOD_IMAGE` (default `runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04`; for
  `graphics`, `RUNPOD_IMAGE_GRAPHICS_DEFAULT` in `bin/lib.sh`: cloudmule's prebuilt image, `images/gpu-graphics`) are for GPU pods.
  On a pod, `MIN_DISK_GB` is the pod's disk (default 30) and `ONESHOT_EXCLUDE` applies.
- `GPU_SELFTEST=<job>`: a job that must pass on the pod after the upload and before the real job (same arguments);
  for any project whose output is pictures (a few frames compared with local ones). `GPU_GRAPHICS_BACKEND`
  (`gl-egl` default, `vulkan` only if the page survives the context-loss check).
- `.cloudmule/files/` (optional) is uploaded to `$REMOTE_DIR/.cloudmule-files` (`$CLOUDMULE_FILES`): helpers the jobs
  `source`, reference data. The rest of `.cloudmule/` is never uploaded.
- Jobs on a pod get `CLOUDMULE_CPUS`/`CLOUDMULE_RAM_GB` (the pod's cgroup allotment: size threads and slots from
  them, never `nproc`), `CLOUDMULE_DEADLINE` (epoch s; stop cleanly before it), and for graphics
  `CLOUDMULE_CHROME_GPU_FLAGS`, `CLOUDMULE_CHROME_ANGLE`, `CLOUDMULE_CHROME_LOG` (tee Chrome's output there).
  `cloudmule-par --slots N tasks.txt` runs a job's independent tasks N at a time (one log, `CLOUDMULE_TASK`,
  `CLOUDMULE_TASK_TMP` each; `TASK …` and `PAR …` lines).

## How it works

**Hetzner bills while a server exists**, running or stopped, per started hour. So it is never "stopped": its
disk is saved as a snapshot (cents per GB per month) and it is deleted. Snapshots: `role=workspace,
scope=shared`, the whole disk of the shared server with every project (only the latest is kept). Everything
cloudmule creates carries the label `managed-by=cloudmule`.

**State on the server** lives in `/root/cloudmule/`: `leases/<project>[--<target>]` (one per active project,
refreshed by every command), `jobs/<lease>-<job>.log`, `scripts/`, `mod/<module>[@<version>]` (installed
modules) and `setup/<project>-<hash>` (server-setup done). Project files live in `/root/work/<project>/`.

**On this computer:** `.env` (token and settings; a setting given in the environment wins, e.g.
`IDLE_MINUTES=10 cloudmule start …`, except RunPod's caps and standing approval: only `.env` counts for those),
`keys/` (this computer's SSH key), `registry/<project>` (each project's folder), `logs/` (every job's log, deleted after `LOG_KEEP_DAYS` = 14; and `usage.tsv`, one line
per job with its peak RAM and CPU time, kept `USAGE_KEEP_DAYS` = 90). None of it is versioned.

**Job usage:** every remote job runs in its own cgroup (a transient systemd scope); when it ends, the wrapper
reads the kernel's `memory.peak` (file cache included: an upper bound), `cpu.stat` and `memory.pressure` (how
long it stalled for lack of RAM: ~0 means the RAM was enough) and writes one line next to its log; `job`/`attach`
collect it exactly once (an uncollected previous run is kept as `.usage.prev`). Nothing is sampled. `n/a` means
the scope could not be created (the job then runs unmeasured).

**Server type:** the user chooses it. `servers` reads the API's server types (`server-type list`: cores, memory,
disk, `cpu_type`, `architecture`, `prices[]`, `locations[].available`) and checks each against the project's
requirements and the saved workspace. `start --type` creates exactly that type, in the cheapest allowed location
(or `--location`); creating without `--type` is refused. The choice is recorded on Hetzner as labels
(`chosen-type`, `chosen-by` = project, `chosen-at` = date) on the server, copied onto the workspace snapshot by
`end --keep` and by the guard: the **last choice** every agent sees (`servers`, `start`'s refusal and join line).
**A snapshot restores only on a disk at least as large as the disk it was taken from** (Hetzner answers
"image disk is bigger than server type disk"; verified 2026-11-14), so the disk of the server the workspace was
saved from is the **disk floor** for every later server (`CONTEXT.md`); `--fresh` starts from plain Ubuntu, and
the next `end --keep` replaces the saved workspace. Shared CPUs (CX, CPX) are cheaper; dedicated (CCX) give full cores for long CPU-bound work.

**Cost guard, on the server:** a systemd timer runs `remote/guard.py` every 5 min and deletes the server after
`IDLE_MINUTES` without activity (session 45, oneshot 20) or `SESSION_MAX_HOURS`/`ONESHOT_MAX_HOURS` up (8 / 3).
In a session it snapshots first: nothing is lost. Activity = an SSH connection or a job's process at one of
its 5-minute looks, and every cloudmule command (it marks the server as used, so short commands between two
looks still count). It works even
if Claude Code is closed or the computer is off. `oneshot` also deletes the server with `trap … EXIT`.

**Remote jobs** run detached from SSH (`{ nohup setsid -f bash -c … & }`), with their log copied to `logs/`. If
the connection drops or the local process is killed, the job goes on: `attach`.

**GPU pods (RunPod, `gpu`).** RunPod's REST API (`https://api.runpod.io/v2`, key in `RUNPOD_API_KEY`) from
`bin/tools.py` (`rp-*`). One SECURE pod per job (COMMUNITY pods have no public SSH), named
`cloudmule-<project>[-<target>]-<job>-<run tag>` (6 random hex: a session's cleanup after a failed create never
matches another session's pod) and its own time cap in its env (`CLOUDMULE_MAX_MINUTES`: orphan checks on any
computer use the pod's cap, not their own), with a throwaway SSH key in `keys/pod-<run>` (deleted with it) and
`NVIDIA_DRIVER_CAPABILITIES=all`. Steps: refusals (none creates anything) → the launch lock (`logs/runpod-launch.lock`:
this computer's launches one at a time from the budget check until the pod exists; a dead holder's lock is removed;
2 min at most) → the pods already running (`RUNNING_PODS`; `RUNPOD_MAX_PODS`) and the budget → the local watchdog
→ create the first candidate that fits (price from the catalog cache; RunPod decides availability; one billed above a
cap is deleted at once) → wait for public SSH → start the in-pod guard → the pod's allotment from its cgroup
(`POD_CPUS`/`POD_RAM_GB`, else the catalog's) → install `base`, `chrome-libs gpu-graphics` (graphics) and `MODULES`:
ONE apt pass for all of them (modules declare packages in `# apt:` headers; `lib/apt-pass.sh`, Ubuntu packages from
`RUNPOD_APT_MIRROR`; download-only modules beside it), then each module's own steps → (graphics) the host's NVIDIA
graphics libraries (`cloudmule-gpu-libs`), the backend's Chrome flags and `cloudmule-webgl-check` (8 s of a
demanding WebGL2 page: renderer before/after, context loss, a canvas texture read back; `GPU_NOT_USED` /
`GPU_CONTEXT_LOST`) → `server-setup.sh` → upload (`SYNC_EXCLUDE` + `ONESHOT_EXCLUDE`, and `.cloudmule/files/`) →
dependencies → `GPU_SELFTEST` → the job, with the watcher (`remote/gpu-watch.sh`: GPU, VRAM, CPU against the
cgroup quota, RAM every 2 s; for graphics also Chrome's log) → its results (also on failure) → `GPU_USE` → (graphics)
`cloudmule-webgl-check --quick` → delete. At `CLOUDMULE_DEADLINE` (the cap − 5 min, or an eighth of a shorter cap)
`gpu` stops the job (TERM to its process group, up to 60 s), downloads what it announced and ends `GPU_TIME_CAP`.
Every run prints `PHASES` (also in `usage.tsv`). A project whose `NEEDS_GPU` is not set is refused (`NEEDS_GPU_UNSET`): the pod could not know
whether to prepare Chrome and Vulkan. Caps in `.env`, enforced in code even when the user approves each pod, and
read only from `.env`: `RUNPOD_MAX_USD_PER_HOUR` (no pod above it; one billed above it is deleted at once),
`RUNPOD_MAX_MINUTES` (every pod is deleted after it; `--max-minutes` can only lower it for one run),
`RUNPOD_MAX_USD_PER_DAY` and the optional `RUNPOD_MAX_USD_PER_MONTH` (the day's / calendar month's spend from
`usage.tsv` + the worst case of running pods + the new pod's worst case must stay below), the optional
`RUNPOD_MAX_PODS` (cloudmule pods running at once; unset = no limit). **Three deletion layers:** the `gpu`
process's EXIT trap; a detached local watchdog (`rp-reap`, started before the pod is created) that deletes it after
`RUNPOD_MAX_MINUTES`; and `remote/pod-guard.sh` inside the pod (started right after SSH answers), which deletes
it with the pod's own credentials (`runpodctl remove pod $RUNPOD_POD_ID`, else the REST API with the pod-scoped
key, else it stops the container) even if this computer is off. **Records:** `logs/runpod/<pod id>.json` from
creation to deletion; whoever deletes a pod writes its one `usage.tsv` line (provider `runpod`, GPU id, minutes,
cost estimate = USD/h × minutes). `gpu`, `gpus` and `status` delete a `cloudmule-*` pod up longer than
its own time cap + 5 min (an orphan); a pod RunPod gives no age for is timed from when this computer first saw it.
`logs/last-gpu` holds the user's last GPU choice (this computer only).

**Sync** compares size and mtime of each file with the server (`find -printf` there, `os.walk` here), uploads
only what differs with `tar` over SSH and deletes there what no longer exists here. `SYNC_SEEDS` (heavy files
the server regenerates) are uploaded only when missing. Downloads use `scp`.

## Developing cloudmule

- Public repository, MIT license, everything in English. Scripts are bash 3.2-compatible (macOS) and must not
  rely on GNU-only options on the local side (`head -n -1`, `sed -i` without suffix, `sha256sum`); the server
  is Ubuntu, GNU tools are fine there.
- Never commit `.env`, `keys/`, `logs/`, `registry/` or anyone's project.
- Tests: `bash tests/run.sh` (no token, no cost: it fakes `hcloud` with recorded fixtures in `tests/fixtures/`,
  RunPod's API with a local server in `tests/fake-runpod/`, and `ssh`/`scp` for pods in `tests/fake-ssh/`;
  GitHub Actions runs it on Linux and macOS). It must pass before every commit. Before a release, also follow
  `docs/e2e-checklist.md` with a real token (costs a few cents: ask first). Specs live in `docs/specs/`.
- New module: `remote/modules/<name>.sh`, idempotent, pinned version, checksum verified. Its apt packages go in
  `# apt:` header lines (`a|b` = whichever this Ubuntu has), installed by `lib/apt-pass.sh` (one `apt-get update`);
  the script itself only does the rest. Versioned modules read `$VERSION` and install into `/opt/<name>/<version>`.
  Helpers that are not modules live in `remote/modules/lib/`. After changing modules, rebuild the graphics image
  (`tests/run.sh` checks `RUNPOD_IMAGE_GRAPHICS_SOURCE` once one is recorded): push the branch and a tag
  `gpu-image-<date>` on it, which runs `.github/workflows/gpu-image.yml` (pushing an image is outward-facing: the
  owner's yes), check the package is
  public (an anonymous pull works: RunPod pulls without credentials), copy the job summary's two lines into
  `bin/lib.sh`, run the tests, commit.

## Gotchas (lessons that cost time)

- Your computer killing background commands when it runs out of RAM also kills local `cloudmule` processes:
  that is why remote work is detached and resumable (`attach`, module markers).
- Measure the network before big transfers; upload once and then only differences; analyse on the server and
  download only results. Verify big downloads with `sha256sum` on both sides.
- Missing dependencies only show up when running for real: run a real job before trusting a new setup.
- Bash: `a && b > log` only redirects `b` (group with `{ a && b; } > log`); `a && b &` backgrounds the whole
  chain (`a && { b & }`); `cmd | grep -q` under `set -o pipefail` can fail with SIGPIPE (`grep … >/dev/null`).
- `python -I` ignores `PYTHON*` variables; on Windows, Python needs Windows paths (`cygpath -w`).
- On Windows, stopping the shell task does not kill its process tree; Git Bash has no `pkill`/`pgrep` (use
  PowerShell `Get-CimInstance Win32_Process` + `Stop-Process` for a local tunnel).
- `scp -r src dest/existing` puts the folder INSIDE the existing one: copy to the parent folder.
- Never edit `bin/cloudmule` while a cloudmule command runs (another session's `gpu`, a test): bash reads a script as
  it executes it, and the running command fails at its end (`unexpected EOF`, exit 2). `bin/lib.sh` is read whole
  when sourced; `bin/tools.py` is started anew by every call, so a change there reaches running commands too.
- GPU rendering in Chrome (specs 0004 and 0005): on a CPU server WebGL falls back to SwiftShader, ~20× slower than a
  laptop's integrated GPU (12.2 s/frame). On a RunPod A40 with ANGLE over GL/EGL a real three.js page renders at
  **0.19 s/frame** (the laptop: 0.55). The "0.03 s/frame" measured first was a **broken** render: with ANGLE over
  Vulkan, Chrome lost the WebGL context while the page loaded and three.js drew on without its canvas textures and
  environment map, with no error. Hence GL by default, the demanding `cloudmule-webgl-check`, and `GPU_SELFTEST`.
  Several Chromes in one pod are fine with GL (6 gave 4–4.7× the frames per second of one, GPU at 30 %): fill the
  GPU with `cloudmule-par` before renting more. The NVIDIA drivers need libglvnd (`libglvnd0`, `libgl1`, `libegl1`):
  without them Chrome **silently** uses SwiftShader. Never install `mesa-vulkan-drivers` (a software Vulkan driver)
  and never write the toolkit's read-only ICD file.
- Inside a RunPod container `nproc` and `/proc/cpuinfo` show the host (96 threads); the pod has its cgroup's quota
  (`cpu.max`: 7.65 vCPUs on an A40, the catalog says 9). Measure and size from the cgroup (`CLOUDMULE_CPUS`).
- Python's `urllib` tries a host's IPv6 addresses first, one connect timeout each: on a network whose IPv6 does not
  answer, every RunPod API call took 42 s (2026-11-19). `bin/tools.py` sorts IPv4 first.
- From RunPod's hosts `archive.ubuntu.com` sometimes crawls (33 kB/s on 2026-11-19: an `apt-get update` took 9–13
  min) while other mirrors and Google's/Node's CDNs answer at MB/s: pods use `RUNPOD_APT_MIRROR`.
- RunPod's PyTorch image is Ubuntu 22.04, `runpod/base` 24.04: modules must work on both (`a|b` package names in
  `# apt:` headers for the `t64` renames), and a tar made on
  Windows needs `tar --no-same-owner` as root in a container. Cheap GPUs are often unavailable: `gpus` reads the
  catalog's availability first.
- A helper taking optional arguments under `set -u` must read them as `${3:-}`: a missing one once crashed a
  DELETE and left a pod running for a minute.
- iOS builds need macOS and Xcode, which Hetzner does not offer. Android emulators need KVM, which Hetzner's
  cloud servers probably don't expose (`ls /dev/kvm`).
