# Spec 0004 — RunPod as a second provider, for work that needs a GPU

Status: agreed 2026-11-18, not started · Scope: the cloudmule repository only.
Vocabulary: see `CONTEXT.md` (shared server, lease, workspace, disk floor, last choice). New terms: **provider**,
**GPU pod**, **standing approval** (defined below; add them to `CONTEXT.md`).

## Problem Statement

cloudmule only rents Hetzner Cloud servers, and Hetzner Cloud has no GPUs. Some heavy work is only fast on a GPU:
rendering WebGL/three.js frames in headless Chrome (video projects), and CUDA work (ML). On a CPU server that
work falls back to software rendering (SwiftShader) and is **~20× slower than a laptop's integrated GPU**
(measured, see Further Notes). Today the user's only options are their own computer (slow, and it fills its RAM)
or renting a GPU by hand outside cloudmule.

The user wants cloudmule to offer both providers, and the agent to pick the right one **per project and per
task**, asking the user what it needs to know, with the same safety rules as today: nothing is created without
the user's choice (or a standing approval with hard limits), nothing is left running, the token is never printed.

## Solution

1. **Two providers.** Hetzner stays as it is (one shared CPU server, sessions, leases, workspace). RunPod is added
   **only for GPU work**, as a **GPU pod**: one pod per job, never shared, created → set up → upload → run →
   download → **deleted** (the `oneshot` model; no sessions, no workspace snapshot, no leases).
2. **The project says what it needs, the agent asks the rest.** `.cloudmule/config.sh` gains `NEEDS_GPU`
   (`0`, `graphics` for WebGL/Vulkan/OpenGL in a browser, `cuda` for compute) and `MIN_VRAM_GB`. The skill decides
   the provider from that and from the task: GPU work → RunPod; everything else → Hetzner. When the project does
   not say, the skill looks at the job (three.js, WebGL, Chrome rendering, PyTorch, CUDA…) and asks the user.
3. **Choosing a GPU is like choosing a server.** `cloudmule gpus <project>` (free) lists the GPUs RunPod has
   **available now** with their price per hour, VRAM, cloud (SECURE / COMMUNITY) and whether they fit, the last
   choice, and a `RECOMMENDED:` line. Creating needs `--gpu <id>` (a comma-separated list of candidates is
   allowed: the first available one within the price cap is used).
4. **Hard limits in code, not in prose.** `.env` holds `RUNPOD_MAX_USD_PER_HOUR`, `RUNPOD_MAX_MINUTES` and
   `RUNPOD_MAX_USD_PER_DAY`. cloudmule refuses to create a pod above the hourly cap, kills it at the time cap, and
   refuses a new pod when today's spend (from `logs/usage.tsv`) plus the new pod's worst case would pass the daily
   cap. These limits apply even when the user approves each pod by hand.
5. **Standing approval (optional).** The user may tell the agent once: "create and delete GPU pods without asking,
   within these limits". The skill records it as `RUNPOD_STANDING_APPROVAL=1` in `.env` **only when the user asks
   for it** (the user can also write it themselves). With it on, the agent may run `gpu` jobs without asking each
   time, always within the caps above, and reports the GPU, price and cost after each job. Without it, every
   creation waits for the user's yes, exactly like Hetzner.
6. **Pods clean themselves up.** Each pod is deleted on job end (`trap … EXIT`), by a local watchdog, **and** by a
   guard inside the pod that removes it after `RUNPOD_MAX_MINUTES` even if this computer is off.

## User Stories

1. As a user with a video project that renders WebGL frames, I want the render to run on a rented GPU, so that a
   10-minute video renders in about 10 minutes for a few cents instead of hours on my laptop.
2. As a user, I want the agent to choose Hetzner or RunPod by looking at the project and asking me what it does
   not know, so that I never pay for a GPU my task cannot use, or wait hours on a CPU for work that needs a GPU.
3. As a user, I want to see which GPUs are available right now and their prices before anything is created, as
   with `servers`.
4. As a user, I want to grant a standing approval with limits (price per hour, minutes per pod, dollars per day),
   so that the agent does not stop to ask for every short GPU job, and I want those limits enforced by cloudmule,
   not only remembered by the agent.
5. As a user, I want a GPU pod to disappear when the job ends, if the job fails, if my computer crashes, and if
   my computer is off, so that a forgotten pod can never drain my balance.
6. As a user, I want `status` to show RunPod pods next to the Hetzner server, and `usage` to show what each GPU
   job cost.
7. As a user, I want my RunPod key handled like the Hetzner token: in `.env`, never printed, never in a project.

## Implementation Decisions

### Provider and API

- **RunPod REST API v2 only** (`https://api.runpod.io/v2`, header `Authorization: Bearer <key>`), called from
  `bin/tools.py` with `urllib` (no new dependency). No MCP servers, no community tools, no RunPod plugin (it needs
  an interactive OAuth login). `runpodctl` is not required on this computer.
- **Key:** `RUNPOD_API_KEY` in `.env`, pasted by the user. It needs **catalog read** permission (without it
  `GET /catalog/gpus` answers 403 and `gpus` cannot show availability: say so and point to RunPod → Settings →
  API Keys). Never printed; never sent to the pod.
- Calls used (all verified 2026-11-18 except where marked):
  - `GET /catalog/gpus?include=AVAILABILITY&product=POD&cloud=SECURE|COMMUNITY` → per GPU: `id`, `memory` (GB),
    `price.secure` / `price.community` (USD/h), `availability` (`NONE`, `LOW`, `MEDIUM`, `HIGH`), `manufacturer`.
  - `POST /pods` with `{name, image, cloud, gpu: {id, count: 1}, disk, ports: ["22/tcp"], env}` → `id`, `cost`
    (USD/h). When nothing is free: HTTP 400 `There are no longer any instances available…`.
  - `GET /pods/{id}` → `status` (`RUNNING`…), `runtime.ports[]` (`private`, `public`, `ip`).
  - `GET /pods` → list (for `status` and for orphan checks).
  - `DELETE /pods/{id}`.
- **SSH:** the pod image reads `PUBLIC_KEY` from its env and authorises it. Use a **per-pod throwaway key**
  generated in `keys/` and deleted with the pod (RunPod pods are not shared, so the per-computer Hetzner key is
  not needed). Connect to `runtime.ports` entry with `private == 22` and a `public` port.
- **Public IP:** SSH needs one. **SECURE pods have it; COMMUNITY pods we tried did not** (no public port 22).
  Default to SECURE. Optionally allow COMMUNITY when the API offers a public-IP filter (to verify:
  `supportPublicIp`); otherwise list COMMUNITY GPUs as "no SSH, not usable" in `gpus`.
- **Image:** default `runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04` (SSH preconfigured, CUDA 11.8 runs
  on current drivers). Overridable per project (`RUNPOD_IMAGE` in `config.sh`). Disk: `MIN_DISK_GB` (default 30).

### Commands

| Command | What it does | Bills? |
|---|---|---|
| `gpus [proj] [--cloud secure\|community]` | GPUs available now: id, VRAM, cloud, USD/h, availability, fits the project (VRAM, cap) and why not, last choice, today's spend and what is left of the daily cap. Last line `RECOMMENDED: <gpu id> <cloud> <usd/h>`: the cheapest fitting GPU with `MEDIUM` or `HIGH` availability, else the cheapest fitting one | No |
| `gpu <proj> [target] --gpu <id[,id…]> [--cloud c] [--dry-run] <job> [args…]` | Checks caps → creates the pod (first candidate available within the hourly cap; a pod created above the cap is deleted at once and the next is tried) → waits for SSH → installs `MODULES` → uploads the project (whole project, `SYNC_EXCLUDE` applies, `ONESHOT_EXCLUDE` too) → runs `.cloudmule/jobs/<job>.sh` → downloads `CLOUDMULE_RESULT` paths → deletes the pod. `--dry-run`: print `WOULD_CREATE: <gpu> <cloud> <usd/h> <max usd>` and stop | **Yes** |
| `status` | Also lists RunPod pods (id, GPU, USD/h, minutes up): those named `cloudmule-*`, and a warning for any other pod in the account | No |
| `usage` | GPU jobs get provider `runpod`, GPU id, minutes and cost | No |

- **Refusals** (exit non-zero, one line, no pod created): `NEEDS_GPU_CHOICE` (no `--gpu`), `ABOVE_HOURLY_CAP`,
  `DAILY_CAP_REACHED`, `NO_GPU_AVAILABLE` (every candidate unavailable), `NEEDS_APPROVAL` (no standing approval and
  the skill did not pass `--approved`; see the skill section), `NO_PUBLIC_SSH` (pod ran but no public port 22 in
  5 min: it is deleted).
- **Pod naming:** `cloudmule-<project>[-<target>]-<job>`; the last choice is kept in `logs/last-gpu` (GPU id, cloud,
  project, date). RunPod has no labels like Hetzner's; one computer's last choice is enough for now.

### Safety

- **Three layers of deletion:** (1) `trap destroy EXIT` in the local `gpu` process; (2) a local detached watchdog
  (`nohup`, survives the process being killed) that deletes the pod after `RUNPOD_MAX_MINUTES`; (3) a **guard inside
  the pod**, started first thing after SSH, that removes the pod after `RUNPOD_MAX_MINUTES` with RunPod's own
  pod-scoped credentials (RunPod injects `RUNPOD_POD_ID` and a pod-scoped `RUNPOD_API_KEY`, and images ship
  `runpodctl`: **to verify** in the e2e run; if not available, fall back to `shutdown`/stop and document that a
  stopped pod still bills for its disk). Layer 3 is what protects against a powered-off computer.
- **Orphans:** every `gpu`, `gpus` and `status` call lists pods; a `cloudmule-*` pod older than
  `RUNPOD_MAX_MINUTES` + 5 is deleted and reported.
- **Bash:** helper functions take optional arguments as `${3:-}` (a missing argument under `set -u` once crashed
  the DELETE and left a pod running for a minute).
- Never `set -x` around requests; never echo the key or the full request headers.

### What the pod needs for GPU rendering in Chrome (`NEEDS_GPU=graphics`)

A new module `remote/modules/gpu-graphics.sh` (Ubuntu, x86), installed before the project's modules:

- `libvulkan1 vulkan-tools libglvnd0 libgl1 libegl1 libgles2` with `--no-install-recommends`. **Not**
  `mesa-vulkan-drivers` (it adds a software ICD). **`libglvnd0`/`libgl1`/`libegl1` are mandatory**: the NVIDIA
  Vulkan driver (`libGLX_nvidia.so.0`) depends on libglvnd's `libGLdispatch`; without them `vkCreateInstance`
  fails and Chrome silently falls back to SwiftShader (this cost two test runs).
- The NVIDIA container toolkit already mounts the graphics libraries and `/etc/vulkan/icd.d/nvidia_icd.json`
  (read-only) when `NVIDIA_DRIVER_CAPABILITIES=all`; set that env var on every pod. Never try to write the ICD
  file. As a fallback only when `libGLX_nvidia.so.0` is missing: extract the same driver version's user-space
  libraries from NVIDIA's `.run` (`sh NVIDIA-Linux-x86_64-<ver>.run -x`), never a different version.
- Google Chrome stable (`.deb`) through the existing `chrome-libs` module plus the browser itself.
- **Chrome flags that use the GPU:** `--headless=new --no-sandbox --use-angle=vulkan --enable-features=Vulkan
  --disable-vulkan-surface --ignore-gpu-blocklist`. The job must check that the WebGL renderer
  (`WEBGL_debug_renderer_info` → `UNMASKED_RENDERER_WEBGL`) contains `NVIDIA` and **fail** if it says SwiftShader:
  a silent software fallback is 100× slower and would burn the time cap.
- Extracting a tar made on Windows as root: `tar --no-same-owner` (or create it with `--owner=0 --group=0`);
  otherwise "Cannot change ownership" aborts the extraction.

### Skill (`plugin/skills/cloudmule/SKILL.md`)

- **Choosing the provider:** read `NEEDS_GPU`. If unset and the task may need a GPU (WebGL/three.js/Chrome
  rendering, video renders with a 3D engine, CUDA/ML), ask the user one question with a recommendation; offer to
  write the answer into `config.sh`. CPU-only work never goes to RunPod.
- **Before a GPU job:** run `gpus <project>`, relay the options, price and the worst-case cost (USD/h ×
  `RUNPOD_MAX_MINUTES`). Without standing approval: recommend one, wait for the user's yes, then
  `gpu … --approved --gpu <id> <job>`. With standing approval: go ahead within the caps and report afterwards.
- **Recording a standing approval:** only when the user explicitly grants one in their own words, write
  `RUNPOD_STANDING_APPROVAL=1` and the caps they gave into `.env`, read them back to the user, and say how to
  revoke it (set it to 0). Never infer it.
- **After every GPU job:** report the GPU, USD/h, minutes and cost; confirm with `status` that no pod is left.
- Plugin version 0.4.0. Update the skill's description: "on a Hetzner server, or a RunPod GPU when the work needs
  one".

### Settings (`.env.example`)

```sh
# RunPod (only for work that needs a GPU). API key with "catalog read" permission
# (runpod.io → Settings → API Keys). Paste it here yourself; never in a chat.
RUNPOD_API_KEY=
RUNPOD_MAX_USD_PER_HOUR=0.70    # never create a pod above this price
RUNPOD_MAX_MINUTES=40           # every pod is deleted after this long, whatever happens
RUNPOD_MAX_USD_PER_DAY=2.00     # refuse new pods when today's spend + the new pod's worst case passes this
RUNPOD_STANDING_APPROVAL=0      # 1 = the agent may create GPU pods without asking, within the caps above
```

`config.sh` (template): `NEEDS_GPU=0` (`graphics` | `cuda`), `MIN_VRAM_GB=8`, optional `RUNPOD_IMAGE`.

## Testing Decisions

- A fake RunPod API for `tests/run.sh`: `RUNPOD_API_BASE` (default the real URL) pointed at a small local Python
  HTTP server in `tests/fake-runpod/` serving fixtures (catalog with mixed availability, a create that answers
  "no instances available", a create above the cap, a pod that becomes RUNNING with and without a public port 22).
  No token, no cost; it runs in GitHub Actions like the fake `hcloud`.
- Through the CLI: `gpus` sorts, marks fit/no-fit and prints `RECOMMENDED`; a 403 catalog prints the permission
  hint; `gpu` without `--gpu` refuses; above the hourly cap refuses; the daily cap refuses using a seeded
  `usage.tsv`; no standing approval and no `--approved` refuses; candidates are tried in order and an above-cap
  pod is deleted; a pod without public SSH is deleted with `NO_PUBLIC_SSH`; the trap deletes the pod on a failing
  job; `--dry-run` creates nothing; the key never appears in any output (grep the test logs for the fake key).
- **e2e (real money, ask first), add to `docs/e2e-checklist.md`:** one `gpu` job on the cheapest available
  SECURE GPU running a WebGL probe (renderer must contain `NVIDIA`); verify the in-pod guard deletes the pod with
  this computer's process killed (`RUNPOD_MAX_MINUTES=5`); verify `status` and `usage` afterwards.

## Out of Scope

- RunPod network volumes (would cache Chrome/Node between pods: ~90 s saved per pod, but they bill per GB per
  month and tie pods to one data centre). Revisit if setup time matters.
- Serverless endpoints, multi-GPU pods, sharing one pod between projects, keeping pods alive between jobs.
- Other GPU providers (Vast.ai was the runner-up in the research: cheaper but marketplace hosts vary more).
- Choosing Hetzner vs RunPod without the user for a project that has never said what it needs.

## Further Notes

- **Measured 2026-11-18** (WebGL three.js scene with accumulation rendering, 1080×1920, 32 samples per frame,
  headless Chrome over CDP):

  | Machine | s/frame | 38 s video (1133 frames) |
  |---|---|---|
  | Laptop, Intel Iris Xe | 0.58 | ~11 min |
  | CPU only (SwiftShader) | 12.2 | ~4 h |
  | **RunPod A40 SECURE, $0.59/h, 1 Chrome** | **0.03** | **~0.5 min** |
  | RunPod A40, 4 Chrome in parallel | 0.15 | ~0.8 min (slower: they fight for the GPU) |

  So **one Chrome per pod**. Pod creation to SSH: 24–35 s; installing Chrome + Node + Vulkan: ~80–100 s.
  A 10-minute video (~18 000 frames) ≈ 9 min of render + ~2 min setup ≈ **$0.11**. Not yet measured: the full
  render with audio mixing and MP4 encoding, and upload/download times.
- **Availability is the real constraint.** Cheap GPUs (3090, A4000, A5000) were often `NONE` in both clouds; the
  catalog call avoids blind create attempts. On 2026-11-18 SECURE had A40 $0.59 (MEDIUM), RTX PRO 4000 Blackwell
  $0.57, L4 / A6000 $0.69 (LOW); COMMUNITY had 3090 $0.22 and 5080 $0.39 but no public SSH.
- A working prototype of this flow (bash + curl) lives in the user's video project that needed it, under
  `tools/runpod/` (`rp.sh`, `run-bench.sh`, `pod-setup.sh`; ask the user for that folder). Use it as a reference for the real calls and the setup order, not as
  code to copy: cloudmule's version goes in `bin/tools.py` / `bin/lib.sh` with tests.
- Written 2026-11-18 after a GPU benchmark; the user asked that cloudmule offer Hetzner and RunPod and decide with
  the user from the project's needs.
