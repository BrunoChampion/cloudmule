---
name: cloudmule
description: Run heavy development work (dependency installs, builds, test suites, project-wide typecheck/lint, dev servers, test browsers, media rendering) on a Hetzner server rented by the hour, or a RunPod GPU when the work needs one, instead of this computer, and set projects up for it. Use before running such work, when the user mentions cloudmule, running something "on the server" or on a GPU, or asks to configure cloudmule in a project.
---

# cloudmule

cloudmule keeps this computer for editing and runs heavy work on one rented server shared by all the user's
projects (Hetzner, CPU only), or, for work that needs a GPU, on a RunPod GPU pod created for one job and deleted
after it. It is a command-line tool in a folder the user cloned; this skill finds it and drives it.

## 1. Find cloudmule

```sh
CM="$(cat ~/.config/cloudmule/home 2>/dev/null)"; echo "${CM:-NOT INSTALLED}"
```

- **Not installed** (no file, or `$CM/bin/cloudmule` missing): say so. To install it, the user clones the
  cloudmule repository, opens Claude Code in that folder and asks "install cloudmule". Until then, do not run
  heavy work silently: follow the user's own instructions about running it locally.
- **Installed:** read `$CM/CLAUDE.md`, sections **Rules** and **Commands**, before the first command of a
  session. The rules (spending money needs confirmation, leases on the shared server) are mandatory.
- Run every command as `bash "$CM/bin/cloudmule" …` (Git Bash on Windows).

## 2. Find the project

`bash "$CM/bin/cloudmule" projects` lists the projects registered on this computer and their folders. The
current project is the one whose folder contains the working directory.

- Listed: read its `.cloudmule/config.sh`, `.cloudmule/jobs/` and `.cloudmule/CLAUDE.md` (if any).
- Not listed, but the folder has `.cloudmule/config.sh` (someone already set it up): run
  `bash "$CM/bin/cloudmule" init <project-folder>`. That only registers it.
- No `.cloudmule/`: set the project up (section 6), after telling the user what you are about to do.

## 3. Choose the provider: Hetzner (CPU) or RunPod (GPU)

Read `NEEDS_GPU` in the project's `.cloudmule/config.sh`:

- `0`, or the work does not need a GPU: **Hetzner**, section 4. CPU-only work never goes to RunPod.
- `graphics` (WebGL/Vulkan/OpenGL in a browser: three.js renders in headless Chrome) or `cuda` (CUDA compute:
  PyTorch, ML), and the task is that kind of work: **RunPod**, section 5.
- **Not set**, and the task may need a GPU (WebGL, three.js, Chrome rendering of frames, video renders with a 3D
  engine, CUDA, PyTorch, ML training or inference): ask the user one question, with a recommendation ("this renders
  WebGL frames: on a CPU server it falls back to software rendering, ~20x slower than a laptop GPU; a GPU pod costs
  about 0.6 USD/h"). Write the answer (`NEEDS_GPU=…`, and `MIN_VRAM_GB` if known) into `config.sh`, with the
  user's OK: `gpu` refuses a project whose `NEEDS_GPU` is not set (`NEEDS_GPU_UNSET`). Never decide alone for a
  project that has not said.

## 4. Run heavy work on the Hetzner server

1. **Choose the server, with the user.** Check `status`. If the server is already running, skip to step 2:
   `start` just joins it (no choice, no new cost decision); tell the user its type and who chose it, and if
   `start` prints `SERVER_BELOW_REQUIREMENTS`, tell them what is missing and let them decide. If no server is
   running:
   - Run `servers <project> [target]` (free). Its output is the source of truth for the choice: relay it in
     plain words, in the user's language, in this order:
     1. The "How to choose" guide, briefly, with the measured needs from `usage <project>` (free): its highest
        peak RAM and cores, when it has records.
     2. The **disk floor**: its current value, or that this choice sets it.
     3. A short table of the types marked `fits`: type, vCPU, RAM, CPU kind, €/h, and each row's disk-floor
        note (`raises disk floor …` / `sets disk floor …`, with the types lost).
     4. The `Cheaper with --fresh` line whenever it appears: the saving per hour against the one-time cost.
     5. The `Last choice` (the user's, from any project or computer) and the `RECOMMENDED` line: propose one of
        them. If `RECOMMENDED` says `none`, explain why and what could change it.
   - **Wait for the user's choice**, also when it repeats the last one: every creation needs their yes.
2. `start <project> [target] --type <chosen>` creates (or joins) the server; `--type` is required to create, and
   it becomes the last choice every agent sees. For a single job, `oneshot <project> [target] --type <chosen>
   <job>` does the same choice, runs the job and deletes the server if nobody else uses it. Add `--dry-run` first if the user
   wants to see exactly what would be created. Report the type and price from the "Creating … EUR/h" line. With
   the server running, `job`, `sync`, `run`, `pull` and `attach` need no new confirmation.
3. `job <project> [target] <job> [args…]` uploads what changed, runs `.cloudmule/jobs/<job>.sh` on the server
   and downloads the files it announces. If a job needs something new (a module, a dependency), change the
   config or the job script and run it again.
4. When done: `end <project> [target] --keep`, then `status`. `end` only deletes the server when no other project
   holds a lease; if it answers `OTHER_PROJECTS_USING_THE_SERVER`, leave it and tell the user.

If the user forgets, the server snapshots itself and deletes itself after 45 idle minutes.

## 5. Run GPU work on a RunPod pod

One pod per job: `gpu` creates it, installs what the project needs, uploads the project, runs the job, downloads
its results and **deletes the pod**. Nothing is shared and nothing stays running. The RunPod key
(`RUNPOD_API_KEY`) is in cloudmule's `.env`, pasted by the user; if it is missing, ask them to create one (RunPod
→ Settings → API Keys, able to manage pods and with "catalog read" permission) and paste it there themselves,
never in the chat.

1. **Show the options** (free): `gpus <project> [target]`. Relay in plain words: the caps (USD/h, minutes per
   pod, USD per day, USD per month), today's and this month's spend and what is left, whether a standing approval is
   on, the GPUs marked `fits` (GPU, VRAM, vCPU, RAM, USD/h, MAX/POD = the worst case of one pod, availability), the
   `Last choice` and the `RECOMMENDED` line (`--all` lists every offer and why it does not fit). If it says
   `RUNPOD_FORBIDDEN`, the key lacks "catalog read": tell the user how to fix it. If it prints `MONTHLY_CAP_NEAR`,
   tell the user before anything else.
2. **Without a standing approval** (`Standing approval: off`): recommend one GPU (a comma-separated list of
   candidates is fine: the first available within the caps is used), say its price and worst case, and **wait for
   the user's yes**. Then `gpu <project> [target] --approved --gpu "<id>[,<id>…]" <job> [args…]`. `--approved`
   means exactly that the user said yes to this pod: never add it otherwise.
3. **With a standing approval** (`Standing approval: ON`): go ahead without asking, within the caps, and report
   afterwards.
4. `--dry-run` prints `WOULD_CREATE: <gpu> <cloud> <usd/h> <max usd>` and creates nothing.
5. **Read what `gpu` prints before the pod:** `RUNNING_PODS: <n>` and one line per cloudmule pod already running,
   from any project, session or computer (name, GPU, minutes up, run tag). Another session's pod running the same job
   is worth a look (and a word with the user) before launching yours. It is a notice, not a block, unless the user set
   `RUNPOD_MAX_PODS`: then `TOO_MANY_PODS` refuses; use `--wait-for-pod <minutes>` instead of retrying in a loop.
6. **While it runs:** `gpu-logs [<run tag>|<pod id>] [-f]` shows the job's log on the pod and its GPU/CPU use now
   (read-only, no confirmation).
7. **After every GPU job** report the GPU, USD/h, minutes and cost (the `GPU pod … deleted:` line) and the
   `GPU_USE` line, then run `status` to confirm no pod is left. If `status` prints `RUNPOD_UNKNOWN` (and fails), it
   could not check every pod: that is not "all clear"; tell the user to look at RunPod's console (Pods).

**How a run ends.** `GPU_OK: <job>` only when the job succeeded, the WebGL check after it passed (graphics) and the
watcher saw no sign of trouble. Otherwise the results are downloaded anyway, for inspection (never call them good):
- `GPU_DEGRADED: <reason>`: the check after the job failed, Chrome's log showed a lost context, a GPU-process crash or
  SwiftShader, or a graphics job left the GPU idle. Tell the user; do not deliver the output as finished.
- `GPU_TIME_CAP`: the job reached its deadline (`CLOUDMULE_DEADLINE`, 5 min before the pod's cap) and was stopped;
  what it had announced was downloaded. `NEAR_TIME_CAP: <n> of <cap> min` on a run that finished: next time split
  the work or speed it up.
- A failed job: its log and the results it announced come back; read them, report, never retry on your own.
- `PHASES …` says how long each step took (also in `usage --phases`).

**Never call a graphics render finished on `GPU_OK` alone if the project has no `GPU_SELFTEST`: say so to the user**
("the GPU drew without errors, but nothing compared the frames with a correct one"), and offer to write a self-test.

Refusals create nothing; explain them and what would change them: `NEEDS_GPU_CHOICE`, `NEEDS_APPROVAL`,
`NEEDS_GPU_UNSET` (section 3), `NO_GPU_NEEDED` (the project says `NEEDS_GPU=0`), `ABOVE_HOURLY_CAP`,
`DAILY_CAP_REACHED`, `MONTHLY_CAP_REACHED`, `ABOVE_TIME_CAP` (`--max-minutes` above `RUNPOD_MAX_MINUTES`),
`TOO_MANY_PODS`, `LAUNCH_LOCK_TIMEOUT` (another launch on this computer held the lock for 2 min: try again),
`GPU_SELFTEST_MISSING`, `NO_GPU_AVAILABLE` (try another GPU or later), `NO_FITTING_GPU` (VRAM, not NVIDIA, a MIG
slice for graphics work, a GPU RunPod does not offer, or COMMUNITY cloud). After creation (the pod is deleted at
once): `NO_PUBLIC_SSH`, `GPU_NOT_USED` (Chrome rendered in software), `GPU_CONTEXT_LOST` (Chrome lost its WebGL
context or drew a canvas texture wrong), `GPU_SELFTEST_FAILED` (the project's own check failed; its results are
downloaded). Never retry a failed GPU job on your own: report and ask.

**Standing approval.** Only when the user explicitly grants one in their own words ("create and delete GPU pods
without asking, up to X USD/h, Y minutes, Z USD a day"): write `RUNPOD_STANDING_APPROVAL=1` and the caps they gave
(`RUNPOD_MAX_USD_PER_HOUR`, `RUNPOD_MAX_MINUTES`, `RUNPOD_MAX_USD_PER_DAY`, `RUNPOD_MAX_USD_PER_MONTH`) into
cloudmule's `.env`, read them back to the user, and tell them how to revoke it (set it to 0). Never infer it. The
caps in `.env` are enforced by cloudmule itself, with or without approval, and cannot be raised for one command.

**What every job gets on a pod:** `CLOUDMULE_CPUS` and `CLOUDMULE_RAM_GB` (the pod's own allotment, from its cgroup:
size threads, encoders and parallel tasks from these, never from `nproc`, which shows the host's 96 threads),
`CLOUDMULE_DEADLINE` (epoch seconds: stop cleanly before it; announce results as they finish, e.g. one chapter at a
time), `CLOUDMULE_FILES` (the project's `.cloudmule/files/`: shared helpers to `source`, reference data).

**Jobs for `graphics`.** Pods have Google Chrome; `/etc/cloudmule/chrome-gpu-flags` (also `$CLOUDMULE_CHROME_GPU_FLAGS`)
holds the flags that make it draw on the GPU: ANGLE over OpenGL ES/EGL (`$CLOUDMULE_CHROME_ANGLE=gl-egl`), software
rendering forbidden. Vulkan only if the project sets `GPU_GRAPHICS_BACKEND=vulkan` and its page survives the
context-loss check (with Vulkan a real three.js page lost its context and rendered wrong pictures with no error).
Before the upload and after the job, `gpu` runs `cloudmule-webgl-check` (a demanding page: context loss, canvas
textures, renderer before and after). A job that launches its own browser (Puppeteer, HyperFrames…) must use
`google-chrome` with those flags, tee Chrome's output (`--enable-logging=stderr`, and the page's console) into
`$CLOUDMULE_CHROME_LOG` so the watcher can see a lost context, and give each Chrome its own `--user-data-dir`.
**A project whose output is pictures should have a self-test** (`GPU_SELFTEST=<job>` in `config.sh`): 3–4 frames
rendered on the pod and compared (SSIM ≥ 0.95) with frames rendered locally; it runs before the real job and stops
the pod when the pictures are wrong.

## 5a. Many tasks on GPUs: fill one GPU first, rent more only when it is full

This applies to any GPU work, not only video: chapters or frame ranges of a render, files to process, batches,
seeds, test shards, prompts to run through a model. When a job is made of **independent tasks**, run several of them
**at the same time inside one pod**, as many as fit without saturating it. That number is the job's **slots**. One pod
pays one setup and keeps one daily-cap reservation; several pods pay a setup each.

1. **Split the job into tasks** of similar size, or into more tasks than slots so the queue balances itself (the
   longest task sets the end). Joining the results is the project's job.
2. **Run them with `cloudmule-par`** (on every pod): a file with one shell command per line, then
   `cloudmule-par --slots N tasks.txt`. Each task gets its own log, `CLOUDMULE_TASK` and a private
   `CLOUDMULE_TASK_TMP` (e.g. Chrome's `--user-data-dir`); it prints `TASK <k> exit=… secs=…` and
   `PAR slots=N tasks=T ok=O failed=F wall=<s>`, and fails if any task failed (the others still finish).
3. **Choose N from measurements, never from guesses:**
   - No measurement yet for this job: `--slots 1` on a short sample of the real work, or the value recorded in the
     project's `.cloudmule/CLAUDE.md`.
   - After a run, read `GPU_USE mean/max · VRAM · CPU (of the pod's vCPUs) · RAM` and the per-task times
     (`GPU_USE_HINT` applies this rule):
     - every resource below ~60 %: raise N (×2, or up to the number of tasks);
     - GPU mean ≥ 85 % or VRAM ≥ 80 %: the GPU is full; N stays or goes down;
     - CPU ≥ 85 % with the GPU low: the CPU is the limit; N stays. A GPU type with more vCPUs (`gpus`, VCPU column)
       or less CPU work per task (a faster encoder preset, smaller read-backs) would help; a stronger GPU would not;
     - RAM ≥ 80 %: N goes down.
   - Memory first: the per-task maximum × N + 20 % must fit in the pod's VRAM and RAM before raising N.
   - CPUs are the pod's allotment (`CLOUDMULE_CPUS`, e.g. 7 on an A40), not the host's. A browser plus an encoder
     needs about 1–2 vCPUs. Measure with the real job (every process it runs), not with a benchmark of one part.
   - Record the N that worked, with its `GPU_USE` line, in the project's `.cloudmule/CLAUDE.md`.
   - Examples: a three.js render on an A40 went from 1 to 6 Chromes at 4–4.7× the frames per second with the GPU at
     30 %; the real job then got half of that because six x264 encoders shared the pod's vCPUs. For `cuda`: several
     independent inference or preprocessing processes on one GPU while VRAM allows; a training run that already
     keeps the GPU near 100 % gets N = 1.
4. **Several pods only as the fallback**, and say which case applies when you propose them:
   - one pod, already full, cannot finish within `RUNPOD_MAX_MINUTES`;
   - one task needs more VRAM than one GPU has (then a bigger GPU, not more pods);
   - the work already saturates one GPU and splitting it is cheaper per unit of work than waiting.
   Start N `gpu` runs (e.g. N background shells), each with `--max-minutes <n>` (≤ the cap) so each reserves only its
   own worst case against the daily cap, and each filled with `cloudmule-par` when its share has several tasks.
5. **Another GPU only by measurement:** compare GPU types by price per unit of work (per frame, file, batch:
   measured), never by price per hour or by name. Move to a stronger GPU only if a run with `cloudmule-par` at its
   best N shows GPU mean ≥ 85 %. CPU-bound work chooses by vCPUs. Above `RUNPOD_MAX_USD_PER_HOUR`, ask the user.

## 6. Set up a project

1. Look at what the project needs, from its files:

   | Found | Means |
   |---|---|
   | `package.json`, `.nvmrc`, `.node-version`, `engines.node` | `node@<that exact version>` (ask if only a range) |
   | `packageManager` in `package.json`, lockfile | the install command (`pnpm install --frozen-lockfile`, `yarn install --immutable`, `npm ci`) |
   | Playwright, Puppeteer, headless Chrome | `chrome-libs` (+ the tool's own browser download in `INSTALL_CMD`) |
   | `requirements.txt`, `pyproject.toml` | `python` (+ venv/uv install in `INSTALL_CMD`) |
   | ffmpeg in scripts | `ffmpeg` |
   | anything else (JDK, Android SDK, Go, Rust…) | `server-setup.sh`, installed into `/opt/<project>/…` with pinned versions and checksums |

   Modules available: `ls "$CM/remote/modules"`. Ask the user when unsure.

   Estimate the server it needs and write `MIN_RAM_GB`, `MIN_CPUS`, `MIN_DISK_GB` in `config.sh`, each with a
   one-line reason as a comment. Rough guide: a typical web app's tests 4–8 GB; several browsers in parallel or a
   big monorepo build 8–16 GB; Android/Gradle builds ≥ 16 GB; video rendering scales with vCPUs (8–16, dedicated
   CPUs if renders are long); disk ≥ 2–3× the project plus its dependencies. Leave the defaults when unsure.

   Decide `NEEDS_GPU` with the user (section 3) when the project renders WebGL/3D in a browser or runs CUDA, and
   write it with `MIN_VRAM_GB`; for anything else write `NEEDS_GPU=0`.
2. Ask one question: commit `.cloudmule/` with the project (recommended: it has no secrets, and worktrees and
   teammates get it) or keep it local to this computer (`--local`, uses git's local exclude).
3. `bash "$CM/bin/cloudmule" init <project-folder> [--name <name>] [--local]`. It copies the template into
   `.cloudmule/` and, unless `--local`, adds a short note to the project's `CLAUDE.md`.
4. Edit `.cloudmule/config.sh`: `MODULES`, `SYNC_EXCLUDE` (never upload secrets, dependencies or build output),
   `INSTALL_*`. Never put secrets in `.cloudmule/`: cloudmule refuses to run if it finds any.
5. Write one job per heavy task in `.cloudmule/jobs/<job>.sh` (see `example.sh`): `set -euo pipefail`, runs in
   the project's folder on the server, prints `CLOUDMULE_RESULT <relative path>` for each file to download.
   Results usually go to a folder the project's `.gitignore` excludes.
6. Fill `.cloudmule/CLAUDE.md` with the jobs table, then run a first job to prove it works. For a GPU job that
   first run creates a paid pod: it follows section 5 (the user's yes, or a standing approval).
