# Spec 0005 — GPU pods that work correctly, say so, start fast, and are used fully

Status: agreed with the owner 2026-11-18 (all open questions decided); implemented and e2e-verified 2026-11-19, prebuilt image published; e2e 1-3 done (see Further Notes) · Scope: the cloudmule
repository only (project-side follow-ups are listed under Further Notes, not specified here).
Builds on: spec 0004 (RunPod GPU pods). Vocabulary: see `CONTEXT.md`. New terms: **context loss**, **GPU self-test**,
**phase timings**, **task**, **slots** (defined below; add them to `CONTEXT.md`).

**cloudmule is not a video tool.** RunPod pods serve any project that needs a GPU: `graphics` (WebGL/Vulkan/OpenGL in
a browser) or `cuda` (ML training and inference, simulations, batch processing). This spec came out of a video project,
so its evidence is about rendering frames. Its parts are of two kinds:
- **For every GPU pod** (`graphics` and `cuda`): faster setup, phase timings, GPU/CPU/VRAM use measured on every run,
  the running-pods notice, and above all the rule in Solution 9: **fill one GPU with parallel tasks before renting
  another**.
- **Only for `graphics`:** the Chrome flags, the WebGL check, the context-loss watcher and the picture self-test
  (Solutions 1–4). `GPU_SELFTEST` itself is generic: any project can declare a check of its own.

## Problem Statement

The first real use of `cloudmule gpu` for WebGL rendering (a video project, three.js in headless Chrome, five pods on
NVIDIA A40 SECURE on 2026-11-18) showed four problems.

1. **Wrong pictures reported as success.** Two full renders ended with `GPU_OK` and a valid MP4, but every frame
   was wrong: canvas textures (3D text flags, cards, ground letters) came out black or empty, and shaded sides
   came out almost black because the environment map was missing.
   - Cause, confirmed by a third pod: with cloudmule's Chrome flags (ANGLE over **Vulkan**), Chrome **loses the
     WebGL context while the real page loads**, then restores it. Three.js does not upload canvas textures or the
     PMREM environment map again, and the render keeps going on the GPU.
   - The page logged `THREE.WebGLRenderer: Context Lost.` / `Context Restored.`. A `webglcontextlost` listener
     added after load saw **0** events, because the loss happens before the page can listen.
   - `cloudmule-webgl-check` passed on the same pods: it only reads the renderer string of an empty page, once,
     before the job.
   - The same page on ANGLE over **OpenGL ES via EGL** (`--use-gl=angle --use-angle=gl-egl`) rendered correctly:
     SSIM 0.995–0.996 against the laptop's frames, and a clean console.
2. **Not faster than the laptop, end to end.** A 38-second Short took about as long on RunPod (~11–12 min) as on the
   user's laptop (~11 min).
   - Pod creation to SSH: ~2–2.5 min.
   - Modules (`base chrome-libs gpu-graphics node ffmpeg`, installed one after another): ~3–4 min.
   - `cloudmule gpus` before launching: more than 2 min.
   - The render itself: ~4 min.
   - The real GPU speed of that page on an A40 is **0.19 s/frame** with GL (the laptop: 0.55). Spec 0004's
     "0.03 s/frame" came from a benchmark that turned out to be the broken Vulkan render.
3. **Two sessions ran two pods at once** without knowing about each other. A warning sent between sessions did not
   reach the second one. Two pods at once are not a problem by themselves: each pod has its own GPU, and the
   daily cap already counts the worst case of the pods running. The problem is that neither session could see the
   other's pod, so the second one reused a job that was failing.
4. **The GPU was mostly idle, and nobody could tell.** Measured with `nvidia-smi` on two later pods:
   - one Chrome rendering used the A40 only **9–12 % on average**: the limit was the CPU work around each frame
     (read-back, JPEG encoding, transfer), not the GPU;
   - six Chromes in the **same pod** (one task each) produced **4–4.7× the frames per second** of one, with the GPU
     still at 22–30 %.
   - So a task that looked like it needed six pods, or a pricier GPU, fitted in one pod at the same price per hour.
     Nothing in cloudmule measured GPU use, so the decision was made blind. The same can happen with `cuda` work: a
     small inference job leaves most of a large GPU unused.
   - **The real job then ran at half the measured speed, for a reason nobody could see:**
     - The long video's final render (6 chapters in parallel, one pod) made ~12 frames/s, not 25.8. The GPU sat at 28 %.
     - The pod has only the CPUs RunPod allots to it: an A40 comes with **9 vCPUs** (catalog `minVcpuCount`).
       `nproc` and `/proc/cpuinfo` inside the container show the host's **96**.
     - The micro-benchmark only drew frames. The real job also encoded six MP4s with x264 `-preset slow`, and
       those competed with the six Chromes for 9 vCPUs.
     - The render took ~28 min, and the pod ran 37 of its 40 minutes. A slightly longer video would have hit the cap
       and lost everything.
     - Nobody could look at the job's log while it ran.

Smaller problems seen on the way:
- `.cloudmule/` is never uploaded, so a job's helper scripts must be written inline with heredocs.
- The log of the pod's WebGL check is not kept next to the job's log.
- There is no record of how long each phase took, which is what this spec needs in order to optimise.

## Solution

1. **GL by default for `graphics`.**
   - `/etc/cloudmule/chrome-gpu-flags` switches from Vulkan to ANGLE over GL/EGL and forbids the software fallback.
   - Vulkan stays available as an explicit opt-in, never as the silent default.
2. **A WebGL check that fails when the real page would fail.**
   - `cloudmule-webgl-check` runs a demanding self-contained WebGL2 page, with no network and no three.js.
   - It listens for context loss from the first line, verifies pixels drawn from a canvas texture, checks the
     renderer before and after, and reads Chrome's console and GPU-process log.
   - It runs before the job **and again after it**.
3. **The project can add its own GPU self-test.**
   - A project names a job (`GPU_SELFTEST=<job>`) that must pass after the upload and before the real job.
   - Typical use: render 3–4 frames and compare them with frames rendered locally.
   - If it fails, cloudmule stops with `GPU_SELFTEST_FAILED` and the pod is deleted.
   - The check in point 2 is generic. Only a project test catches a wrong picture of *that* project.
4. **Failing loudly during the job, and measuring every run.**
   - On every GPU pod, a watcher records GPU use, VRAM, CPU and RAM (Solution 10).
   - For `graphics` jobs it also scans Chrome's GPU-process log.
   - A context loss, a GPU-process crash or a SwiftShader renderer turns the end result into
     `GPU_DEGRADED: <reason>` (non-zero exit) instead of `GPU_OK`, even if the job's own command succeeded.
5. **RunPod only: show the pods already running, and an optional cap.** This concerns `cloudmule gpu` alone. The
   Hetzner shared server (sessions, leases) is unchanged.
   - Before creating a pod, `gpu` lists the cloudmule pods already running (from RunPod's `GET /pods`, across every
     project, session and computer). It prints one line per pod (project, job, age, run tag) and then goes on.
     This is a notice, not a block.
   - `RUNPOD_MAX_PODS` in `.env` is **unset by default (no limit)**. If the user sets it, a new `gpu` beyond it is
     refused with `TOO_MANY_PODS`, and `--wait-for-pod <minutes>` queues instead of failing.
6. **Faster setup, in two steps, both approved by the owner (2026-11-18).**
   - (a) First, with no new infrastructure: a lighter default image for `graphics`, one combined `apt-get` pass for
     all modules, and no full catalog query when `--gpu` is given.
   - (b) Then a **prebuilt Docker image** for `graphics`, with Chrome, the GL/Vulkan loaders, Node and ffmpeg baked
     in, built from a Dockerfile in this repo and published with a pinned digest. Pods then skip the module
     installs.
   - (a) ships first and its phase timings are recorded, so the gain of (b) is measured, not assumed.
7. **Phase timings in every GPU run.** The job log and `logs/usage.tsv` record each phase: catalog, create, boot to
   SSH, each module, WebGL check, upload, self-test, job, post-check, download and delete.
8. **Small fixes.**
   - `gpus` caches the catalog for a few minutes and shows only the fitting rows by default (`--all` for every row).
   - `.cloudmule/files/` (new, optional) is uploaded to the pod.
   - The WebGL check's output is appended to the job's log.
9. **Fill one GPU before renting another (main rule, any GPU work).** When a job is made of independent **tasks**
   (chapters of a video, files to process, batches, seeds, test shards, prompts…), the default is to run several of
   them **at the same time inside one pod**, as many as fit without saturating it. That number is the job's **slots**.
   - A pod is saturated when GPU use, VRAM, CPU or RAM is near its limit (rule of thumb: GPU mean ≥ 85 %, VRAM or RAM
     ≥ 80 %, or every CPU thread busy), or when one more task no longer raises total throughput.
   - One pod pays one setup and keeps one daily-cap reservation. Several pods pay a setup each.
   - **Several pods are the fallback, not the default.** Use them only when:
     - one pod, already full, cannot finish within `RUNPOD_MAX_MINUTES`;
     - one task needs more VRAM than one GPU has (then a bigger GPU, not more pods);
     - the work is already saturating one GPU, and splitting it is cheaper per unit of work than waiting.
   - cloudmule gives jobs a small runner for this, `cloudmule-par` on every pod: it runs a list of task commands with
     N slots, one log and one exit code per task, and fails the job if any task fails (Implementation Decisions).
   - The fallback stays safe: a lock serialises budget check and pod creation (parallel launches cannot all pass the
     daily cap), and a per-run `--max-minutes <n>` (≤ the cap) makes each pod reserve only its own worst case.
   - Joining the tasks' results is the project's job.
10. **Measure, then decide: GPU, CPU and VRAM use on every GPU run.** The watcher (point 4, extended to every GPU pod)
    prints one line per run: `GPU_USE mean max · VRAM max · CPU mean · RAM max`. The skill reads it with a fixed
    decision rule (Implementation Decisions), so the next run uses more slots, fewer slots, another GPU or more pods
    for a measured reason.
    - **A pricier GPU is never chosen before a run shows the GPU is the bottleneck.** If the CPU is the bottleneck, a
      GPU type that comes with a faster or larger CPU may help; that is a measured choice too.

## User Stories

1. As a user rendering video frames on a rented GPU, I want cloudmule to say `GPU_OK` only when the GPU really drew
   the pictures, so that a broken render never looks finished.
2. As a user, I want the pod to stop before the long render when the GPU cannot draw my page correctly, so that I pay
   for minutes, not for a wrong 10-minute video.
3. As a user, I want my project to add its own picture check, because only my project knows what a correct frame looks
   like.
4. As a user who runs several Claude sessions, I want each `gpu` run to show the RunPod pods other sessions already
   have running, so that agents know about each other without depending on messages. I also want to be able to cap
   how many pods run at once if I ever need to, without a cap by default.
5. As a user, I want a GPU render to be clearly faster than my laptop end to end, so that renting is worth it. Target
   for a 38-second Short: under 7 min from command to MP4.
6. As a maintainer, I want each run to say how long every phase took, so that I can see where the minutes go.
7. As a user with a job made of many independent tasks (a video's chapters, a folder of files to process, a batch of
   inferences), I want cloudmule to run as many of them as fit on one GPU at the same time, so that I pay one setup
   and one pod instead of many, and the job still finishes fast.
8. As a user, I want every GPU run to tell me whether the GPU, the CPU or the memory was the limit, so that the next
   run uses more parallel tasks, more pods or another GPU for a measured reason, and I never pay for a pricier GPU
   that would sit idle.
9. As a user of `cuda` work (not video), I want the same rule and the same measurements, because the same waste
   (a big GPU used at 10 %) happens there too.

## Implementation Decisions

### Chrome flags (`remote/modules/gpu-graphics.sh`)

- `/etc/cloudmule/chrome-gpu-flags` becomes:
  `--headless=new --no-sandbox --ignore-gpu-blocklist --use-gl=angle --use-angle=gl-egl --disable-gpu-watchdog --disable-software-rasterizer`.
  - Validated 2026-11-18 on A40, driver 595.112.07, Chrome 158.0.8127.36.
  - Renderer: `ANGLE (NVIDIA Corporation, NVIDIA A40/PCIe/SSE2, OpenGL ES 3.2)`.
- The same flags are exported to jobs as `CLOUDMULE_CHROME_GPU_FLAGS`, and the ANGLE backend as
  `CLOUDMULE_CHROME_ANGLE=gl-egl`, so a job that starts Chrome itself does not need to parse the file.
- `GPU_GRAPHICS_BACKEND=vulkan` in a project's `config.sh` selects the old Vulkan flags, plus
  `--disable-software-rasterizer`.
  - Documented as "only if your page survives the context-loss check".
  - The check in the next section is the guard: with Vulkan, the three.js page lost its context in 3 flag variants
    out of 3.
- Keep `libglvnd0 libgl1 libegl1 libgles2` (EGL needs them too). Keep the driver-matched fallback for missing
  graphics libraries; add `libnvidia-eglcore` and `libEGL_nvidia` to what it checks.

### `cloudmule-webgl-check` v2

- A self-contained HTML page, written by the module, with no network and no libraries. It:
  1. registers `webglcontextlost` on the canvas **before** calling `getContext('webgl2')`;
  2. reads `UNMASKED_RENDERER_WEBGL`;
  3. allocates what broke the real page: a 4096² depth texture/FBO (shadow-map-sized), RGBA16F/RGBA32F render
     targets (`EXT_color_buffer_float`), and a 2048² cube map;
  4. uploads a 2D canvas with drawn text as a texture, draws it to a quad, and `readPixels` a known spot (it must
     match the canvas colour within a tolerance);
  5. runs an accumulation loop into the float target for **≥ 8 s of wall time**;
  6. reads the renderer and the canvas-texture pixel again;
  7. prints one line `CHECK renderer_before=… renderer_after=… lost=<n> texel_ok=<0|1> frames=<n>`.
- Run with `--enable-logging=stderr --v=0` and a time budget (`--virtual-time-budget` or a page that writes its
  result only when done, with `--dump-dom` after a `timeout`). The implementer chooses; the check must not end
  before the loop does.
- It **fails** when any of these hold:
  - the renderer before or after lacks `NVIDIA`;
  - `lost > 0`;
  - `texel_ok=0`;
  - stderr has `GPU process exited`, `GPU process crashed`, `SwiftShader`, `Context Lost` or `context lost`.
- Its whole output goes to the pod's log and is appended to the local job log (`logs/<project>-<job>-*.log`).
- Exit codes: `GPU_NOT_USED` (renderer not NVIDIA) and `GPU_CONTEXT_LOST` (loss or bad texel), before the upload;
  the pod is deleted.
- **Post-check:** after `run_job`, `gpu` runs `cloudmule-webgl-check --quick`, 2 s of the same page. If it fails,
  the run ends `GPU_DEGRADED: post-check failed` (exit ≠ 0), and the job's results are still downloaded for
  inspection.

### Project GPU self-test (`config.sh`: `GPU_SELFTEST=<job>`)

- Optional. After `setup_project` (upload), `gpu` runs `.cloudmule/jobs/<selftest>.sh` with the same arguments as
  the main job.
  - Exit 0: the main job starts.
  - Anything else: `GPU_SELFTEST_FAILED`, the self-test's `CLOUDMULE_RESULT` files are downloaded, and the pod is
    deleted.
- The self-test's minutes count towards the pod's cap like everything else.
- The template's `CLAUDE.md` and the skill explain when to write one: any project whose output is pictures. The
  pattern: a few frames compared by SSIM with frames rendered locally, references in `.cloudmule/files/` or in the
  project. `.cloudmule/files/` is the one subfolder of `.cloudmule/` that gets uploaded (new, see Small fixes); today
  `bin/lib.sh` excludes all of `.cloudmule/`, so until this ships the references must live elsewhere in the project.

### Watcher on every GPU pod (`remote/gpu-watch.sh`, started like `pod-guard.sh`)

- Runs on **every** GPU pod (`graphics` and `cuda`) from the start of the job to its end.
- Every 2 s it appends to `$R/gpu-watch.log` one line with:
  - `nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits`;
  - CPU use **of the pod's own allotment**, from the container's cgroup:
    - `usage_usec` delta in `/sys/fs/cgroup/cpu.stat`, divided by the quota in `/sys/fs/cgroup/cpu.max` (cgroup v1:
      `cpuacct.usage` and `cpu.cfs_quota_us`/`cpu.cfs_period_us`);
    - **never** `/proc/stat`, `nproc` or `/proc/cpuinfo`: inside a RunPod container they show the whole host (96
      threads on an A40 host whose pod is allotted 9 vCPUs), so the pod would look 10× emptier than it is;
  - RAM used against the cgroup's `memory.max` (not `/proc/meminfo`, which is the host's).
- At pod start, `gpu` reads the allotment once and exports it to jobs as `CLOUDMULE_CPUS` (quota ÷ period, rounded
  down, at least 1) and `CLOUDMULE_RAM_GB`, and prints them (`POD_CPUS=9 POD_RAM_GB=50`). Jobs size their
  parallelism and their encoders' threads from these, never from `nproc`. If no quota is found, it falls back to the
  catalog's `minVcpuCount` for that GPU, and says so.
- At the end of the job, `gpu` prints the summary line and copies it into the job log and into `usage.tsv`:
  `GPU_USE mean=<%> max=<%> · VRAM max=<MiB>/<total> · CPU mean=<%> · RAM max=<GiB>/<total>`.
- **Only for `graphics`:** jobs that start Chrome are encouraged to pass `--enable-logging=stderr` and tee it to a
  file named in `CLOUDMULE_CHROME_LOG` (exported). The watcher scans that file for the patterns of the WebGL check.
  - Pattern hit → `GPU_DEGRADED: <pattern> at <time>`.
  - Mean GPU use under 5 % while the job ran more than 60 s → `GPU_DEGRADED: GPU idle` (for `graphics` that means
    Chrome fell off the GPU).
  - It is a warning-level failure: exit ≠ 0, results downloaded.
- The watcher never kills the job. It only judges the result, so a false positive costs a re-check, not a lost
  render.
- For `cuda`, a low GPU use is not an error. It is reported, and the decision rule below turns it into "more slots".

### Running pods notice and optional `RUNPOD_MAX_PODS` (RunPod only)

- Applies only to `gpu` (RunPod). `start`, `oneshot` and the Hetzner leases do not read `RUNPOD_MAX_PODS`.
- Why no limit by default: pods are never shared, so two pods do not slow each other down (the slowdown measured in
  spec 0004 was several Chromes inside **one** pod). Spending is already bounded by `RUNPOD_MAX_USD_PER_DAY`, which
  counts the worst case of running pods.
- Before `rp-launch`, `gpu` lists `GET /pods` and keeps the pods whose name carries cloudmule's prefix, in any status
  other than terminated, across all projects. It prints `RUNNING_PODS: <n>` and one line per pod (project, job,
  minutes, run tag). The skill tells the agent to read those lines: another session's pod running the same job is
  worth a look before launching.
- `RUNPOD_MAX_PODS` (`.env`, unset = no limit): when set and the count is ≥ it, the result is `TOO_MANY_PODS` with
  the same lines, exit ≠ 0, nothing created. `--wait-for-pod <minutes>` polls every 30 s until a slot is free or the
  time runs out; agents use it instead of retrying in a loop. Like the other RunPod caps, it lives in `.env` and
  cannot be raised from the environment.
- **Launch lock, always on (cap or not).** Parallel launches (the fallback of Solution 9) would each see "0 pods
  running" and each pass the daily-cap check. A local lock file in `$CM_DIR/logs/runpod-launch.lock` is held from `gpu_budget` until
  `rp-launch` returns, so each launch counts the worst case of the pods created before it.
  - Waiting for the lock is bounded (2 min, then `LAUNCH_LOCK_TIMEOUT`).
  - A lock left by a dead process is detected (pid not alive) and removed.
  - Across computers the race is accepted and documented.

### Filling one GPU: tasks, slots and `cloudmule-par` (Solution 9, main rule)

- **`cloudmule-par`**, installed on every GPU pod by the `base` module, is a small runner for a job's tasks. It is
  generic: it knows nothing about Chrome, video or ML.
  - Input: a file with one shell command per line (one task each), and `--slots N`.
  - It runs at most N tasks at once and starts the next as soon as one ends.
  - Each task gets its own log (`$CLOUDMULE_PAR_LOGS/<k>.log`) and its own environment:
    - `CLOUDMULE_TASK=<k>`;
    - `CLOUDMULE_TASK_TMP=<private temp dir>`, so tasks that need a private profile or cache do not collide (for
      Chrome, a `--user-data-dir` each).
  - At the end it prints one line per task (`TASK <k> exit=<c> secs=<s>`) and `PAR slots=N tasks=T ok=O failed=F
    wall=<s>`. It exits ≠ 0 if any task failed; the others still run to the end, so their results are kept.
- **Choosing N (the slots).** The skill's rule, from measurements, never from guesses:
  1. With no measurement for this job yet: `--slots 1` on a short sample of the work, or the project's recorded
     value (e.g. in its `.cloudmule/CLAUDE.md`).
  2. After a run, read `GPU_USE`/`VRAM`/`CPU`/`RAM` and the per-task times:
     - every resource below ~60 %: raise N (×2, or up to the number of tasks);
     - GPU mean ≥ 85 % or VRAM ≥ 80 %: the GPU is full; N stays or goes down (a stronger GPU or more pods are the
       options, see below);
     - CPU ≥ 85 % with the GPU low: the CPU is the limit; N stays. A GPU type that comes with more or faster CPU
       cores, or less CPU work per task (project side), would help; a stronger GPU would not;
     - RAM ≥ 80 %: N goes down.
  3. Record the value that worked, with its measurements, in the project (e.g. its `.cloudmule/CLAUDE.md`), so the
     next session starts there.
- Memory limits are the hard ones: VRAM and RAM are checked **before** raising N, with the per-task maximum observed
  × N + 20 % margin ≤ the pod's total.
- **CPUs are the pod's allotment (`CLOUDMULE_CPUS`), not the host's.** A task that runs a browser plus an encoder
  needs about 1–2 vCPUs; on a 9-vCPU A40 pod, 6 such tasks are already more than the CPUs. The skill writes this
  plainly: measure with the real job (every process it runs), not with a micro-benchmark of one part of it.
- **More, smaller tasks than slots.** When tasks differ in size, the longest one sets the end (in the L001 render, a
  3,600-frame chapter ran beside a 2,226-frame one). Split the work into tasks of similar size, or into more tasks than
  slots so the queue balances itself. `cloudmule-par` starts the next task as soon as a slot frees, so many small tasks
  even out.
- **Evidence (2026-11-18, A40, `graphics`):** 1 / 3 / 6 Chromes rendering in parallel gave 15 / 40 / 71 frames per
  second at review quality and 6.4 / 15.4 / 25.8 at final quality, with the GPU at 9–12 % → 22–30 %. 6 slots in one
  pod beat 6 pods: same speed, one setup, one-sixth of the daily-cap reservation.
  - **The real job got half of that** (~12 frames/s): it also ran 6 encoders on the pod's 9 vCPUs. One pod was still
    the right call (correct video, 0.36 USD, no cap raised), but slots must be judged on the real job, with the CPU
    measured against the allotment.
- `cuda` examples where the same rule applies: several independent inference or preprocessing processes on one GPU
  while VRAM allows. A training run that already keeps the GPU near 100 % gets N = 1.

### Several pods (Solution 9, fallback)

- Only when one full pod is not enough (Solution 9's three cases). The skill says which case applies when it
  proposes several pods.
- **Per-run time cap:** `gpu … --max-minutes <n>`, with `n` ≤ `RUNPOD_MAX_MINUTES` (a higher value is refused, never
  raised).
  - It sets the in-pod guard, the local watchdog, the pod's `CLOUDMULE_MAX_MINUTES` env and the worst case reserved
    against the daily cap.
  - Example: five pods on A40s at 0.59 USD/h with the default 40 min each reserve 5 × 0.39 = 1.97 USD, which would
    block the 5th pod on any day with earlier spending. With `--max-minutes 25` it is 5 × 0.25 = 1.23 USD.
- cloudmule does **not** orchestrate the split. The project starts N `cloudmule gpu` runs (e.g. N background shells),
  each downloading its own results.
  - What cloudmule guarantees: distinct run tags, keys and watchdogs per run (already true), the launch lock above,
    and a clear per-run summary.
- Each of those pods should itself be filled with `cloudmule-par` when its share has several tasks.
- **Joining the results is the project's job.** For Short Form (owner's decision, 2026-11-18): the chapters of a long
  video are joined and the audio mixed **on the owner's PC, only if it is light** (ffmpeg concat with `-c copy` plus
  one audio mix).
  - Ask the owner's permission first, because of the PC's RAM rule.
  - If that step turns out heavy (re-encoding, long mixes), it runs in the pod at the end of the job instead.

### Choosing another GPU (Solution 10)

- The `GPU_USE` line is the only evidence that counts. Compare GPU types by **price per unit of work** (per frame,
  per file, per batch: measured), never by price per hour or by name.
- Move to a stronger GPU only if a run with `cloudmule-par` already at its best N shows GPU mean ≥ 85 %.
- **CPU-bound work chooses by vCPUs, not by GPU.** When the CPU is the limit and the GPU is low, the useful
  difference between pod types is the CPU allotment.
  - `gpus` shows two more columns from the catalog: `vCPU` (`minVcpuCount`) and `RAM` (`minRam`).
  - Catalog on 2026-11-18 (SECURE):

    | GPU | vCPU | RAM | USD/h |
    |---|---|---|---|
    | A40 | 9 | 50 GB | 0.59 |
    | RTX A6000 | 9 | 50 GB | 0.69 |
    | RTX PRO 4000 Blackwell | 9 | 24 GB | 0.57 |
    | L4 | 6 | 55 GB | 0.69 |
    | RTX 4090 | 8 | 31 GB | 0.89 |
    | L40S | 16 | 62 GB | 1.09 |

  - **To verify on a real pod:** whether `POST /pods` can ask for more vCPUs per GPU (RunPod's pod API has had
    `minVcpuCount`/`vcpuCount`-style fields). If it can, a CPU-bound job may get more CPUs on the same GPU. Record
    the answer in Further Notes. Never pass such a field without checking its price effect first.
- If a stronger GPU is above `RUNPOD_MAX_USD_PER_HOUR`, the skill asks the owner, as for any cap.

### Faster setup

Step (a), in this spec:
- **Lighter default image for `graphics`.**
  - `RUNPOD_IMAGE_DEFAULT` stays the PyTorch/CUDA image for `cuda`.
  - For `graphics`, a new `RUNPOD_IMAGE_GRAPHICS_DEFAULT`: a small Ubuntu 22.04/24.04 image from RunPod that
    authorises `PUBLIC_KEY` for SSH (candidate: `runpod/base`, exact tag pinned after a test). `graphics` does not
    need the CUDA toolkit.
  - Measure boot-to-SSH with both images and record it in Further Notes.
- **One apt pass for a pod's modules.** For GPU pods, `ensure_modules` runs one `apt-get update` and one
  `apt-get install` with the union of the modules' apt packages before each module's own steps. Modules declare
  their apt packages in a `# apt:` header line, read by `lib.sh`.
  - The Google Chrome repository is added before that single update.
  - Node (tarball) and ffmpeg (static build) may download in parallel with the apt pass.
- **No catalog wait when the GPU is named.** `rp-launch` with `--gpu <id>` tries `POST /pods` directly and uses the
  catalog only to read the price for the caps. The price comes from a catalog cache (`logs/runpod-catalog.json`,
  valid 10 min, refreshed in the background by `gpus`). With no cache, it queries only the named ids if the API
  allows it, otherwise the full catalog as today.
- **Target after (a):** command → job start ≤ 3 min on an A40 SECURE.

Step (b), prebuilt Docker image (approved by the owner 2026-11-18; built after (a) so its gain is measured):
- `images/gpu-graphics/Dockerfile` in this repo: the pinned base image plus everything in `gpu-graphics`, `node`
  and `ffmpeg`. Chrome is **pinned by the image digest**, which also fixes "Google keeps no older Chrome".
  - The Dockerfile reuses the module scripts (`COPY remote/modules` + `RUN`), so pods and image never drift apart.
  - It keeps the same safeguards: the Google key fingerprint check and the NVIDIA checksum rule.
  - The NVIDIA driver libraries are **not** baked in: they come from the host (container toolkit), and the
    driver-matched fallback still runs at pod start if they are missing.
- Built by a GitHub Action on demand (`workflow_dispatch`) and pushed to GitHub Container Registry as a **public**
  image. It holds no secrets, and a public image needs no registry credentials on RunPod.
  - Referenced as `RUNPOD_IMAGE_GRAPHICS_DEFAULT=ghcr.io/<owner>/cloudmule-gpu-graphics@sha256:<digest>`, always by
    digest, never by tag.
  - The first push and making the package public are outward-facing: the implementing agent confirms them with the
    owner at that moment.
- `gpu` skips installed modules (the existing `$R/mod/<spec>` markers are baked into the image). On each pod it
  still runs `cloudmule-webgl-check`: a prebuilt image is no proof that this pod's driver works.
- Rebuild when Chrome needs updating or a module changes. A test in `tests/run.sh` fails if the module scripts
  changed since the digest in the settings was built (a hash of `remote/modules/*` recorded with the digest).
- **Target after (b):** command → job start ≤ 1.5 min.

### Phase timings

- `gpu` stamps each phase with `date +%s` and prints a final line, for example
  `PHASES catalog=3 create=12 ssh=95 modules=180 webgl=14 sync=8 selftest=40 job=230 postcheck=4 pull=5 delete=2`.
- `logs/usage.tsv` gains a `phases` column with the same string, and `usage` can show it (`usage --phases`).

### Small fixes

- `gpus`: default output = fitting rows + `RECOMMENDED:` + caps; `--all` for the full list. It writes the catalog
  cache above.
- `.cloudmule/files/` (optional) is uploaded to `$REMOTE_DIR/.cloudmule-files/`, exported as `CLOUDMULE_FILES`.
  The rest of `.cloudmule/` stays excluded: `config.sh` is settings, not data.
  - Main use besides reference data: **helpers shared by a project's jobs**. Today each job is sent to the pod alone,
    so the Short Form project repeats the same Chrome flags, GPU check and GPU-use summary in four jobs. With this, a
    job can `source "$CLOUDMULE_FILES/<helper>.sh"`.
- **Download results even when the job fails.** Today `run_job` stops when the remote job exits ≠ 0, before
  `pull_results`. So a failed job's own log and partial results never reach the computer; only cloudmule's local log
  does. Change: always run `pull_results` (best effort: a missing path is reported, not fatal), then propagate the
  job's exit code. This applies to Hetzner jobs too.
  - Found 2026-11-18 by a code review of the Short Form jobs: their skill told agents to "read the job's log" after
    a failure, and that log was never downloaded.
  - Test: a fake job that announces a result and exits 1 → the result is downloaded and `gpu`/`job` still exit ≠ 0.
- **A deadline before the cap, so a long job is not lost whole.** The L001 render used 37 of 40 minutes; at the cap,
  the in-pod guard deletes the pod and every result goes with it.
  - At `cap − 5 min` the local watchdog sends `TERM` to the job's process group on the pod and waits up to 60 s.
  - Then it runs `pull_results` for whatever the job had announced so far (jobs may announce results as they finish
    them, e.g. one finished chapter), deletes the pod, and ends with `GPU_TIME_CAP: stopped at <n> min; partial
    results downloaded`.
  - Jobs see the deadline as `CLOUDMULE_DEADLINE` (epoch seconds) and may stop cleanly before it.
  - The in-pod guard stays as the last resort at the cap itself (computer off or watchdog dead).
  - When a run ends within 15 % of its cap, `gpu` prints `NEAR_TIME_CAP: <n> of <cap> min` so the agent splits the
    work or speeds it up next time.
- **A monthly cap: `RUNPOD_MAX_USD_PER_MONTH`** in `.env` (the owner set 15 USD on 2026-11-18, for one long video a
  week and two Shorts a day).
  - Enforced exactly like `RUNPOD_MAX_USD_PER_DAY`: this calendar month's spend (from `logs/usage.tsv`) plus the
    worst case of running pods plus the new pod's worst case must stay under it. Otherwise
    `MONTHLY_CAP_REACHED`, nothing created.
  - `gpus` and `usage` show the month's spend next to the day's, and `usage --month` lists it by project.
  - At 80 % of the cap, every `gpu` prints `MONTHLY_CAP_NEAR: <spent> of <cap> USD`, so the agent warns the owner
    early.
  - Unset means no monthly cap. Like the other caps, it cannot be raised from the environment.
  - Note: `usage.tsv` holds cloudmule's estimates; RunPod's billing stays authoritative.
- **See a running job's log: `cloudmule gpu-logs [<run tag>|<pod id>] [-f]`.** Today nobody can look at a pod while
  its job runs.
  - It shows the tail of the job's output on the pod over SSH (the run's key stays local until the pod is deleted),
    plus the watcher's last `GPU_USE`/CPU line. `-f` follows it.
  - With no argument, it uses this computer's newest running cloudmule pod. It is read-only, so it needs no
    confirmation.

### Skill and docs

- `plugin/skills/cloudmule/SKILL.md`:
  - new result codes (`GPU_CONTEXT_LOST`, `GPU_SELFTEST_FAILED`, `GPU_DEGRADED`, `TOO_MANY_PODS`,
    `LAUNCH_LOCK_TIMEOUT`), the `RUNNING_PODS` notice, and the `GPU_USE` and `PAR` lines;
  - a "many tasks" section, written for any GPU work (examples from rendering **and** from `cuda`):
    - split the job into independent tasks;
    - fill one pod with `cloudmule-par` and the slots rule;
    - several pods only in the fallback cases, with `--max-minutes`;
    - another GPU only by the rule of "Choosing another GPU";
  - "never call a graphics render finished on `GPU_OK` alone if the project has no self-test: say so to the user";
  - `--wait-for-pod` instead of retrying.
- `CLAUDE.md` and spec 0004's Further Notes: correct the "0.03 s/frame" figure (a broken render) to the measured
  0.19 s/frame for that page, GL, A40.
- **Remove "one Chrome per pod"** where it is stated as a rule: `plugin/skills/cloudmule/SKILL.md` (~line 118,
  "One Chrome per pod: several in parallel…"), `CLAUDE.md` (~line 229, "One Chrome per pod (several fight for the
  GPU)") and spec 0004's Further Notes (~line 207). It came from the broken Vulkan benchmark. With GL, 6 Chromes in one
  pod gave 4–4.7× the throughput of one (Further Notes of this spec). Replace it with the slots rule of Solution 9.

## Implementation Order

Each phase ends green on `bash tests/run.sh` (a light suite: bash + Python with fake APIs, fine to run locally).
Each phase gets one commit per feature, only if the owner asks for commits; otherwise staged, as in spec 0004.
The daily cap is shared with the Short Form sessions, which now render long videos on RunPod (reviews and final):
before each real-money step run `status` and `usage`. If today's spend plus the step's worst case would pass the cap,
wait or note it in the questions file; never raise a cap.
Real-money steps follow the owner's standing authorisation (≤ 0.70 USD/h per pod, 40 min, ≤ 2 USD/day, ≤ 15 USD per
month across all projects: keep the implementation's own e2e spend small, about 1–2 USD in total) and are
reported with GPU, USD/h, minutes and cost.

1. **Correct pictures** (the urgent part):
   - GL flags and the `GPU_GRAPHICS_BACKEND` opt-in;
   - `cloudmule-webgl-check` v2 and its post-check;
   - `GPU_SELFTEST`;
   - the watcher with `GPU_DEGRADED` and `GPU_USE`;
   - `.cloudmule/files/` upload;
   - results downloaded even when the job fails;
   - the deadline before the cap (`CLOUDMULE_DEADLINE`, `GPU_TIME_CAP`, `NEAR_TIME_CAP`) and `gpu-logs`;
   - the monthly cap (`RUNPOD_MAX_USD_PER_MONTH`, `MONTHLY_CAP_REACHED`, `MONTHLY_CAP_NEAR`);
   - the check log appended to the job log.
   - Checkpoint: the real-pod tests of the WebGL check (GL must pass; Vulkan must be caught), then e2e 1 with step (a)
     not yet done (baseline phase timings).
2. **Phase timings and faster setup, step (a):**
   - the `PHASES` line and `usage.tsv` column;
   - lighter `graphics` image;
   - one apt pass;
   - catalog cache and `gpus` short output.
   - Checkpoint: e2e 1 again; compare phases with the baseline.
3. **Using the GPU fully, then several pods:**
   - the watcher on every GPU pod with the full `GPU_USE` line;
   - `cloudmule-par`;
   - the skill's "many tasks" section;
   - running-pods notice, optional `RUNPOD_MAX_PODS` / `--wait-for-pod`;
   - launch lock and `--max-minutes`.
   - Checkpoint: e2e 2 (below).
4. **Prebuilt Docker image, step (b):** Dockerfile, GitHub Action, module-hash test.
   - Stop and confirm with the owner before the first push and before making the package public.
   - Checkpoint: e2e 1 with the image; record the phases.
5. **Docs:** skill, `CLAUDE.md`, `CONTEXT.md` terms, the 0.03 → 0.19 correction in spec 0004, and Further Notes of
   this spec with the measured numbers.

Questions that do not block the work go to `.scratch/0005-gpu-graphics/owner-questions.md`, with the default taken,
as in spec 0004.

### The Short Form project, for the e2e runs

- Path: `C:\Users\bruno\Documents\Short Form`. Its `.cloudmule/` is local (not in git); its job
  `.cloudmule/jobs/render-short.sh` already contains the diagnosis, the SSIM check and the GL fallback. The
  reference frames are in `episodes/001-eratosthenes/pod-ref/`.
- For e2e 1, the implementing agent may:
  - create `.cloudmule/jobs/gpu-selftest.sh` there, by moving the diagnosis and SSIM part out of `render-short.sh`;
  - set `GPU_SELFTEST=gpu-selftest` in its `.cloudmule/config.sh`;
  - drop the job's own flag variants once the defaults are GL.
- That project's other jobs (`render-long.sh`, `review-long.sh`, `measure-*.sh`) are used by its own sessions, and the
  implementing agent leaves them alone. They keep their own checks (gl-egl flags, NVIDIA renderer, "Context Lost",
  SSIM against `pod-ref/`), so they keep working before and after this implementation.
- It touches nothing else in that project. Before any pod, it reads that project's
  `docs/cloudmule-runpod-aprendizajes.md` (the project's rule) and appends its results there, in Spanish, as a new
  dated section.
- Project-side follow-ups (the `make-long` chapter split, the join on the owner's PC, its own parallel render job
  `.cloudmule/jobs/render-long.sh --parallel`) are **not** part of this implementation. They are listed in Further
  Notes for the Short Form sessions. Once `cloudmule-par` exists, that project's jobs may switch to it; that is the
  project's change, not this one.
- The owner's global rules forbid heavy local work (renders, test browsers, `pnpm install`) on their PC without
  permission. The e2e renders run on RunPod only.

## Testing Decisions

- `tests/run.sh` (fake SSH and fake RunPod API, as today) covers:
  - the `RUNNING_PODS` notice with no cap (it never blocks), and `TOO_MANY_PODS` and `--wait-for-pod` with a cap;
  - the self-test hook (pass, fail and download);
  - the post-check turning `GPU_OK` into `GPU_DEGRADED`;
  - the watcher's summary parsing;
  - the `PHASES` line and the `usage.tsv` column;
  - the catalog cache;
  - module `# apt:` header parsing;
  - the launch lock: two simultaneous `gpu` runs whose worst cases together pass the daily cap → exactly one is
    refused; a stale lock from a dead pid is removed;
  - `--max-minutes`: above the cap → refused; below it → guard, watchdog, pod env and reserved worst case all use it;
  - the `GPU_USE` summary line (GPU, VRAM, CPU, RAM) from a recorded watcher log, for `graphics` and `cuda`;
  - a job that announces a result and exits ≠ 0: the result is downloaded, and the command still exits ≠ 0;
  - the deadline: a fake job that runs past `cap − 5 min` gets `TERM`, its announced results are downloaded, the
    pod is deleted, and the result is `GPU_TIME_CAP`; a run ending within 15 % of the cap prints `NEAR_TIME_CAP`;
  - `CLOUDMULE_CPUS`/`CLOUDMULE_RAM_GB` from fake cgroup files (v2 and v1), and the fallback to the catalog's
    `minVcpuCount`; the watcher's CPU % computed against the quota, not the host;
  - `gpu-logs` against the fake SSH;
  - the monthly cap: a `usage.tsv` with this month's spend near the cap → `MONTHLY_CAP_NEAR`; over it with the new
    pod's worst case → `MONTHLY_CAP_REACHED` and nothing created; last month's lines not counted;
  - `cloudmule-par`: N slots never exceeded, the next task starts when one ends, per-task logs and exit codes,
    private `CLOUDMULE_TASK_TMP`, exit ≠ 0 when one task fails while the others finish;
  - the image's module hash check.
- The new WebGL check page is tested **on a real pod** with real money (the owner's standing authorisation covers
  ≤ 0.70 USD/h per pod, 40 min, ≤ 2 USD/day, no limit on simultaneous pods). Per backend:
  - GL: it must pass on an A40.
  - Vulkan: it must reproduce the loss. If it passes on Vulkan while the three.js page fails, the check is not
    demanding enough; add what the page does (PMREM-style cube render, many texture uploads) until it catches it.
- e2e 1: render the Short Form project's 001 episode with `GPU_SELFTEST` = its 4-frame SSIM test, defaults only (no
  per-job flag overrides), and record the phase timings and the total against the ≤ 7 min target. Do it once with
  step (a) and once with the image of step (b).
- Before e2e 2, read the Short Form learnings document: the L001 long video's final render (2026-11-18, one pod,
  6 chapters in parallel with that project's own `render-long.sh --parallel`, GPU use logged) is real-world evidence
  for the slots rule. Its numbers go into Further Notes.
- e2e 2: `cloudmule-par` on a real pod. A job of 6 independent tasks (the Short Form long video's 6 chapters, or a
  synthetic GPU load if that video is not ready) with `--slots 1`, then `--slots 3` and `--slots 6`. Record per run:
  wall time, `PAR`, `GPU_USE`, phases and cost, and apply the slots rule. Expected from the 2026-11-18 measurement:
  near-linear gain up to 6 for that rendering load.
- e2e 3 (only if a `cuda` project is available): the same with a `cuda` load, to check the watcher and the rule
  outside rendering. If none is available, record it as not done.

## Out of Scope

- Making Vulkan survive the context loss (it may be the page's GPU memory use, a Chrome bug or the driver).
  Investigated project-side if the GL speed is not enough.
- The project's render pipeline speed (JPEG capture over CDP, encoding, samples per frame). See Further Notes.
- Keeping pods alive between jobs, network volumes, sharing a pod between sessions (spec 0004's decisions stand,
  unless the owner reopens them in Open Questions).

## Open Questions (for the owner)

All decided by the owner on 2026-11-18; kept here as the record.

1. **Prebuilt image:** yes. A public GHCR image built from a Dockerfile in this repo, pinned by digest, built after
   step (a) so its gain is measured. The first push and making the package public are confirmed with the owner when
   they happen.
2. **Many tasks: one GPU first, more pods second (decided 2026-11-18, replaces an earlier "one pod per chapter").**
   For any GPU work, not only video, the main option is to run as many tasks at once on one GPU as fit without
   saturating it; several pods only when one full pod is not enough. The owner asked that cloudmule explain this as a
   general evaluation, not as a video rule.
   - Applied to the Short Form long video: one pod with 6 chapters in parallel instead of 6 pods. Done on
     2026-11-18: ~28 min of render, pod 37 min, ~0.36 USD, correct pictures. It was half the speed estimated from
     the micro-benchmark (CPU-bound on the pod's 9 vCPUs: see Problem 4).
   - Results are joined on the owner's PC only if that step is light, with permission each time (RAM rule);
     otherwise at the end of the pod's job.
3. **Simultaneous pods:** no limit by default, RunPod only. The owner dropped "one pod at a time" from the
   authorization: the daily cap already bounds spending. `RUNPOD_MAX_PODS` exists for whoever wants a limit.
4. **GPU choice:** a stronger GPU would not help the Short Form work. Even at final quality with 6 Chromes, the A40
   was at 28–30 % on average. A pricier GPU is chosen only by the rule of "Choosing another GPU".
   - **Update 2026-11-18: more CPU is allowed.** The owner accepted the L40S (16 vCPUs, 1.09 USD/h) for CPU-bound work
     ("the price difference is negligible"). The Short Form project raises its hourly cap to 1.10 USD for that and
     asks for `--gpu "NVIDIA L40S,NVIDIA A40"`.
   - The cloudmule defaults do not change: `RUNPOD_MAX_USD_PER_HOUR` stays 0.70 unless the owner's `.env` says
     otherwise.

## Further Notes

- **Evidence, 2026-11-18, A40 SECURE 0.59 USD/h, driver 595.112.07, Chrome 158.0.8127.36.** Logs in
  `logs/short-form-render-short-20261118-{1847,1850,1912}.log`; the full write-up, in Spanish, is in the Short Form
  project, `docs/cloudmule-runpod-aprendizajes.md`.

  | Pod | Backend | s/frame (32 samples) | Console | Picture | Pod minutes / USD |
  |---|---|---|---|---|---|
  | k939e2gl1vxhra (ep. 001) | Vulkan | 0.24–0.27 | Context Lost/Restored | broken (SSIM 0.82–0.91) | 10.9 / 0.108 |
  | qipww75b7d6meo (ep. 011) | Vulkan | 0.24 | Context Lost/Restored | canvas textures missing | 10.2 / 0.100 |
  | p81ni3v53g5xbj (ep. 001) | **GL (gl-egl)** | **0.19** | clean | **correct (SSIM 0.995–0.996)** | 11.9 / 0.117 |

  - In pod 3's diagnosis, three Vulkan flag variants (plain, `--disable-gpu-watchdog`, native Vulkan with
    `VulkanFromANGLE,DefaultANGLEVulkan`) all showed NVIDIA before and after, and all logged Context Lost.
  - The morning's 0.03 s/frame benchmark used the same Vulkan flags and never checked pictures or the console. Treat
    it as a broken render.
  - The old `cloudmule-webgl-check` passed on all three pods.
- **Where the minutes went** (pod 2, typical): command 18:39:28 → pod with SSH ~18:42 → modules 18:42–18:45 →
  upload 4 s (142 files, 31.5 MB) → render ~4.5 min → delete. Upload is negligible; boot and modules are ~half the
  run.
- **Project-side follow-ups (Short Form, not this repo):**
  - its render job keeps the SSIM self-test and the console check;
  - investigate why ANGLE-GL costs 0.19 s/frame (GPU time, JPEG/CDP capture or encoding: measure each);
  - check whether Vulkan survives with smaller shadow maps or without PMREM, for a possible ~6× speed-up;
  - long-video renders in **one pod with the chapters in parallel** (`render-video --chapter <id> --profile <own
    dir>` per chapter; already in its `render-long.sh --parallel`), then the join and the audio mix on the owner's
    PC if light and with permission; update the `make-long` skill accordingly;
  - long-video **review rounds also on RunPod** (owner's decision, 2026-11-18): one pod per round with every changed
    chapter at once (that project's `.cloudmule/jobs/review-long.sh`), same quality as the PC. Another "many tasks on
    one GPU" case: a 3-chapter round is ~2–3 min of render plus setup and download, ~0.10 USD, against ~15 min on the
    PC. Shorts' reviews stay on the PC until the Docker image cuts setup to ~1.5 min (then measure again);
  - review renders that still run on the PC: half-size shadow maps (SSIM 0.9996, −45–65 %), 6 samples at half size,
    strips taken from the film frames (measured in that project's `bench/results.md`).
- **Measured 2026-11-18 on an A40 (GL), Short Form long video L001** (two pods, 0.10 + 0.08 USD; data in that project's
  `bench/results.md` and `bench/a40-review/`, `bench/a40-parallel/`):

  | Load | 1 task | 3 tasks | 6 tasks | GPU mean with 6 |
  |---|---|---|---|---|
  | Review (960×540, 6 samples), frames/s | 15.1 | 40.5 | 71.0 | 22 % |
  | Final (1920×1080, 32 samples), frames/s | 6.4 | 15.4 | 25.8 | 30 % |

  - One real review of a chapter (1,115 half-size + ~180 full-size frames): 135 s, GPU mean 12 %.
  - The limit is per-frame CPU work (read-back, JPEG, transfer), not the GPU.
- **The real long-video render** (Short Form L001, 2026-11-18, pod `pok1e9o4ir80ld`, A40 SECURE; that project's
  learnings document has the details):

  | | Estimated from the micro-benchmark | Measured |
  |---|---|---|
  | Frames/s, 6 chapters at once, 32 samples | 25.8 | **~12** |
  | Render | ~11 min | **~28 min** |
  | Pod (with setup, upload, download) | ~17 min | **37 min of 40** |
  | Cost | ~0.17 USD | **~0.36 USD** |
  | GPU mean | 30 % | 28 % (max 77 %) |

  - Setup ~2.5 min to SSH + ~2.5 min of modules. Upload 214 files / 59.9 MB. Download 272 MB in ~1 min. Joining and
    mixing on the owner's PC: 19 s.
  - Cause (strong hypothesis, matches the catalog): 6 Chromes + 6 x264 `-preset slow` encodes on the A40 pod's 9 vCPUs.
    The micro-benchmark had no encoder, and the host's 96 threads hid the allotment.
  - Lessons for cloudmule: measure CPU against the cgroup allotment, export `CLOUDMULE_CPUS`, show vCPUs in `gpus`,
    set a deadline before the cap, provide `gpu-logs`, and decide slots from the real job.
  - Project-side ideas (not cloudmule): faster x264 preset per chapter, equal-size frame ranges instead of chapters,
    half-size shadow maps.
- **Implementation, measured 2026-11-19** (all on NVIDIA A40 SECURE at 0.59 USD/h; details in
  `.scratch/0005-gpu-graphics/owner-questions.md` and, in Spanish, in the Short Form learnings document):
  - **WebGL check v2 on a real pod** (`hqbovmeeqgst2u`, 6.5 min, ~0.064 USD): GL/EGL passed (NVIDIA before and after,
    `texel_ok=1`, ~4,800 accumulation frames in 8 s); Vulkan was caught (`CONTEXT_LOST_WEBGL`, `lost=1`, `texel_ok=0`).
    On that pod Vulkan lost the context at once (`Failed to send GpuControl.CreateCommandBuffer`) instead of during the
    page load as on 2026-11-18; the check counts losses from the first line and reads a canvas texture back after its
    loop, so it catches both.
  - **The pod's own allotment** (cgroup v2): `cpu.max` 765000/100000 = **7.65 vCPUs**, `memory.max` ≈ 50 GB, on every
    A40 measured (the catalog says 9 vCPUs; `nproc` says 96). An L40S pod had 13.6 vCPUs (catalog 16).
  - **e2e 1, baseline** (pod `uzzamw3mnhzmjg`, 10.4 min, ~0.102 USD): Short Form 001 with its 4-frame SSIM self-test
    (0.9944 / 0.9951 / 0.9952), render 1,128 frames at 0.19 s/frame in 3.7 min, `GPU_OK`. Command → MP4 **12.6 min**:
    budget + catalog + create ~2.2 min, SSH ~0.4, modules ~3.5, check + upload ~0.6, self-test ~0.5, render ~4.6,
    post-check + download + delete ~0.8. GPU mean 27 %, CPU 44 % of 7.65 vCPUs.
  - **Why the catalog took minutes:** every RunPod API call from the owner's computer took ~42 s, also the failing
    ones: Python's `urllib` tried `api.runpod.io`'s two IPv6 addresses first (no answer on that network, ~21 s each).
    `bin/tools.py` now sorts IPv4 first: `gpus` went from >2 min to ~4 s, budget + catalog + create to ~3 s.
  - **e2e 1 with step (a)** (pod `rxuq3613ao3hr9`, 11.8 min, ~0.116 USD): `PHASES budget=2 catalog=0 create=1 ssh=82
    modules=332 (apt=294) webgl=13 sync=13 selftest=43 job=211 pull=8 postcheck=7 delete=1`, command → MP4 11.9 min.
    The single apt pass was slow because **`archive.ubuntu.com` answered RunPod's hosts at 33 kB/s** (measured from a
    pod: kernel.org's Ubuntu mirror 6.5 MB/s, Google's Chrome CDN 218 MB/s, nodejs.org 228 MB/s); another session's
    L40S pod lost 787 s of apt the same hour. Pods now take Ubuntu's packages from `RUNPOD_APT_MIRROR`
    (`https://mirrors.edge.kernel.org/ubuntu`, falling back to the image's sources): modules 125 s (apt 63 s) on the
    next pod. The remaining ~17 s per module was cloudmule's own 20 s polling, now 2 s doubling up to 20.
  - **Boot to SSH by image:** `runpod/pytorch:2.1.0…` 47 and 59 s; `runpod/base:1.6.0-ubuntu2404` (0.7 GB) 82 and
    120 s, probably not cached on RunPod's hosts. So the "lighter graphics image" of step (a) did not pay off; the
    graphics default stays the PyTorch image until the prebuilt image (step b) is published.
  - **`POST /pods` and more vCPUs per GPU:** not tried (no field was sent to RunPod's API without knowing its price
    effect); still open.
  - **e2e 2** (pod `r6p8gfqsjdsnbe`, 7.3 min, ~0.072 USD, `--max-minutes 25`): 6 equal tasks of a synthetic WebGL load
    (`cloudmule-webgl-check --frames 9000`) with `cloudmule-par` at 1 / 3 / 6 slots in one pod: 110 / 41 / 30 s
    (1× / 2.7× / 3.7×), GPU mean 31 / 55 / 78 % (max 41 / 79 / 100 %), CPU 8 / 26 / 57 % of 7.65 vCPUs, VRAM 0.9 / 1.9 /
    3.7 GB. Near-linear to 3 slots, then the GPU fills: the slots rule's case "GPU near 85 %: keep N or +1". This load
    is GPU-bound; the real three.js renders are CPU-bound (see the L001 numbers above).
  - **Step (b), the prebuilt image** (owner's yes 2026-11-19): built by `.github/workflows/gpu-image.yml` from the tag
    `gpu-image-2026-11-19` (a `workflow_dispatch` needs the workflow on the default branch; a tag runs it from any
    branch), 2 min on GitHub's runner; `ghcr.io/brunochampion/cloudmule-gpu-graphics@sha256:133b28e4…`, 1.14 GB
    compressed (25 layers), public from the start (a package published with `GITHUB_TOKEN` from a public repository
    takes the repository's visibility; an anonymous manifest pull answered 200). Source hash `f098a23bd0ee45cd`.
  - **e2e 1 with the image** (pod `pxblv75xqkf0zh`, 6.8 min, ~0.067 USD): `PHASES budget=3 prep=0 catalog=0 create=3
    ssh=36 modules=2 webgl=16 sync=20 selftest=42 job=270 pull=15 postcheck=9 delete=2`, `GPU_OK`, SSIM 0.9944 /
    0.9951 / 0.9952, render 3.9 min. **Against the targets:** command → job start was **122 s with the project's
    42-s self-test, which misses "≤ 1.5 min" by 32 s** (80 s to the self-test); command → MP4 was **6 min 59 s**
    (13:10:02 → 13:17:01): under 7 min by one second, so the Short target is met only at the edge (baseline 12.6 min).
    What is left before the job: SSH 36 s, the WebGL check 16 s, the upload 20 s (80.9 MB), the self-test 42 s. The
    first pod with the image (`o0fstfc6flwuf3`, 5.1 min, ~0.05 USD) never showed public SSH within 300 s; the cause
    is not proven (most likely the image's first pull on that host). The boot allowance (`RUNPOD_BOOT_SECONDS`,
    counted once from the pod's creation) is now 600 s.
  - **e2e 3 (cuda)** with a small probe project (PyTorch 2.1.0+cu118 on the CUDA image; pod `tl8gntu1ld830x`, A40, 3.2
    min, ~0.032 USD; the RTX 2000 Ada candidate was not available): 6 tasks of 4,000 synchronised 1024×1024 matmuls
    (latency-bound, like a small inference job) with `cloudmule-par` at 1 / 3 / 6 slots: 21 / 11 / 9 s (each task ~0.6 s
    of GPU work plus ~2–3 s of CUDA start-up). The watcher works the same for `cuda`: `GPU_USE mean=19% max=100% · VRAM
    max=1600/46068 MiB · CPU mean=29% of 7.65 vCPUs`, no `GPU_DEGRADED`, and the hint "room for more parallel tasks".
    Setup: SSH 36 s, modules 55 s (`base` only, apt 29 s through the mirror).
  - Cost of the implementation's own pods: about 0.75 USD (eleven A40 pods, two of them diagnosis pods stopped in the
    slow apt pass, one that never showed SSH).
- Written 2026-11-18 from a review between three Claude sessions of the Short Form project (two of them ran the pods
  above), at the owner's request, then extended the same day with the GPU-use and parallel measurements.
