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
   pod, USD per day), today's spend and what is left, whether a standing approval is on, the GPUs marked `fits`
   (GPU, VRAM, USD/h, MAX/POD = the worst case of one pod, availability), the `Last choice` and the `RECOMMENDED`
   line. If it says `RUNPOD_FORBIDDEN`, the key lacks "catalog read": tell the user how to fix it.
2. **Without a standing approval** (`Standing approval: off`): recommend one GPU (a comma-separated list of
   candidates is fine: the first available within the caps is used), say its price and worst case, and **wait for
   the user's yes**. Then `gpu <project> [target] --approved --gpu "<id>[,<id>…]" <job> [args…]`. `--approved`
   means exactly that the user said yes to this pod: never add it otherwise.
3. **With a standing approval** (`Standing approval: ON`): go ahead without asking, within the caps, and report
   afterwards.
4. `--dry-run` prints `WOULD_CREATE: <gpu> <cloud> <usd/h> <max usd>` and creates nothing.
5. **After every GPU job** report the GPU, USD/h, minutes and cost (the `GPU pod … deleted:` line), then run
   `status` to confirm no pod is left. If `status` prints `RUNPOD_UNKNOWN` (and fails), it could not check every
   pod: that is not "all clear"; tell the user to look at RunPod's console (Pods).

Refusals create nothing; explain them and what would change them: `NEEDS_GPU_CHOICE`, `NEEDS_APPROVAL`,
`NEEDS_GPU_UNSET` (section 3), `NO_GPU_NEEDED` (the project says `NEEDS_GPU=0`), `ABOVE_HOURLY_CAP`,
`DAILY_CAP_REACHED`, `NO_GPU_AVAILABLE` (try another GPU or later), `NO_FITTING_GPU` (VRAM, not NVIDIA, a MIG
slice for graphics work, a GPU RunPod does not offer, or COMMUNITY cloud). `NO_PUBLIC_SSH` and `GPU_NOT_USED` (Chrome rendered in software)
happen after creation: the pod is deleted at once. Never retry a failed GPU job on your own: report and ask.

**Standing approval.** Only when the user explicitly grants one in their own words ("create and delete GPU pods
without asking, up to X USD/h, Y minutes, Z USD a day"): write `RUNPOD_STANDING_APPROVAL=1` and the caps they gave
(`RUNPOD_MAX_USD_PER_HOUR`, `RUNPOD_MAX_MINUTES`, `RUNPOD_MAX_USD_PER_DAY`) into cloudmule's `.env`, read them
back to the user, and tell them how to revoke it (set it to 0). Never infer it. The caps in `.env` are enforced by
cloudmule itself, with or without approval, and cannot be raised for one command.

**Jobs for `graphics`.** Pods have Google Chrome with Vulkan; `/etc/cloudmule/chrome-gpu-flags` holds the flags
that make it render on the GPU (`--headless=new --no-sandbox --use-angle=vulkan --enable-features=Vulkan
--disable-vulkan-surface --ignore-gpu-blocklist`). Before rendering, `gpu` runs `cloudmule-webgl-check` (fails
unless the WebGL renderer is NVIDIA). A job that launches its own browser (Puppeteer, HyperFrames…) must use
`google-chrome` with those flags, and should check its own renderer too. One Chrome per pod: several in parallel
are slower (they fight for the GPU).

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
