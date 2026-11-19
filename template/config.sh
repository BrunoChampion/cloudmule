# cloudmule settings for this project. Sourced by bash: keep it to assignments (and simple shell).
# NEVER put secrets here: this folder may be committed with your project, even to a public repository.
# The Hetzner token lives only in cloudmule's own .env; the project's secrets stay where the project keeps them.

PROJECT_NAME=my-project   # lowercase letters, digits and dashes (set by `cloudmule init`)

# One sub-folder per piece of work (e.g. one folder per video)? Then every command takes a [target] after the
# project name, available below as $TARGET.
NEEDS_TARGET=0
# TARGET_EXAMPLE=video-01

# What gets uploaded: the project folder ($PROJECT_ROOT) by default. With targets, e.g. "$PROJECT_ROOT/$TARGET".
LOCAL_DIR="$PROJECT_ROOT"
# Where it lives on the server: always under /root/work/<project>/ (the server is shared by all your projects).
REMOTE_DIR="/root/work/$PROJECT_NAME"

# What the server must have installed for this project (cloudmule/remote/modules/). Versioned modules take
# @<version>; several versions live side by side, so projects with different versions don't clash.
#   node@<version>  Node.js + corepack (pnpm, yarn). Use the project's version (.nvmrc, engines, `node --version`).
#   chrome-libs     system libraries for headless Chrome (Playwright, Puppeteer…; the browser comes from the tool)
#   ffmpeg          ffmpeg + ffprobe 8.1 (static build)
#   python          Python 3 venv + numpy
# Anything else (a JDK, Android SDK, a CLI…): write it in server-setup.sh (start from server-setup.sh.example).
MODULES="node@24.15.0"

# The server this project needs: `cloudmule servers` only recommends types that meet these, and `start` refuses
# a type that doesn't. Defaults: 4 GB RAM, 2 vCPU, 40 GB disk. Write the reason next to each value you set.
# MIN_RAM_GB=8      # e.g. "the test suite runs 4 browsers in parallel"
# MIN_CPUS=4
# MIN_DISK_GB=80

# Does this project's work need a GPU? Then it runs on a RunPod GPU pod instead (`cloudmule gpu`), one pod per
# job, deleted at the end. Not set = the project has not said: the agent asks the user.
#   0         no GPU: everything runs on the Hetzner server (CPU only)
#   graphics  WebGL / Vulkan / OpenGL in a browser (three.js renders in headless Chrome): installs Chrome + Vulkan
#   cuda      CUDA compute (PyTorch, ML)
# NEEDS_GPU=graphics   # e.g. "renders three.js frames in headless Chrome"
# MIN_VRAM_GB=8        # GPU memory the work needs (default 8)
# RUNPOD_IMAGE=runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04   # the pod's image (SSH ready). Defaults:
#                             # graphics: cloudmule's prebuilt image (Chrome, Node, ffmpeg)
# On a pod, MIN_DISK_GB is the pod's disk (default 30 GB there).
# GPU_SELFTEST=gpu-selftest   # a job (jobs/<name>.sh) that must pass on the pod before the real job, with the same
#                             # arguments: e.g. render 3-4 frames and compare them (SSIM) with frames rendered locally.
#                             # If it fails: GPU_SELFTEST_FAILED, its results are downloaded, the pod is deleted.
# GPU_GRAPHICS_BACKEND=gl-egl # graphics only: Chrome's WebGL backend. gl-egl (ANGLE over OpenGL ES/EGL) is the default;
#                             # vulkan only if your page survives the context-loss check (cloudmule-webgl-check).
# Files for the jobs (helpers they `source`, reference frames…) go in .cloudmule/files/: uploaded to
# $REMOTE_DIR/.cloudmule-files, given to jobs as $CLOUDMULE_FILES. The rest of .cloudmule/ is never uploaded.

# Never uploaded (space-separated). Without "/" = any file or folder with that name; with "/" = that exact path.
SYNC_EXCLUDE="node_modules .git .env .env.* dist build .next .expo __pycache__ .venv *.log"
# Heavy files the SERVER generates: uploaded only if missing there, never overwritten (unless --with-generated).
SYNC_SEEDS=""
# Extra excludes only for `cloudmule oneshot` (e.g. raw material a single job does not need).
ONESHOT_EXCLUDE=""

# Dependencies on the server: INSTALL_CMD runs when a trigger file changed or INSTALL_CHECK fails.
# Use the project's own package manager and lockfile.
INSTALL_CMD="pnpm install --frozen-lockfile"
INSTALL_TRIGGERS="package.json pnpm-lock.yaml pnpm-workspace.yaml"
INSTALL_CHECK="test -d node_modules"
