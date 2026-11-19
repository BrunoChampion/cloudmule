# module: gpu-graphics — GPU rendering in headless Chrome (WebGL through ANGLE over OpenGL ES/EGL by default) on a
# RunPod GPU pod (NVIDIA). cloudmule installs it first, on pods of projects with NEEDS_GPU=graphics. It installs the
# EGL/GL/Vulkan loaders, Google Chrome stable (Google's signed apt repository: Google keeps no older versions to pin),
# Chrome's GPU flags (/etc/cloudmule/chrome-gpu-flags.<backend>) and `cloudmule-webgl-check` (lib/webgl-check.py next to
# this file), which fails unless Chrome draws a demanding WebGL2 page on the NVIDIA GPU without losing its context.
# arch: x86
# apt: ca-certificates curl gnupg pciutils libvulkan1 vulkan-tools libglvnd0 libgl1 libegl1 libgles2 fonts-liberation
# apt: google-chrome-stable
#
# Lessons from the measurements (docs/specs/0004 and 0005):
# - Vulkan (ANGLE over Vulkan) lost the WebGL context of a real three.js page while it loaded, on A40 pods (driver
#   595.112.07, Chrome 158): canvas textures and the environment map came out black. ANGLE over GL/EGL drew it
#   correctly (SSIM 0.995-0.996 against a laptop's frames). So GL is the default; Vulkan only on request
#   (GPU_GRAPHICS_BACKEND=vulkan in the project's config.sh), always behind cloudmule-webgl-check.
# - libglvnd0/libgl1/libegl1 are mandatory: the NVIDIA Vulkan driver (libGLX_nvidia.so.0) needs libglvnd's
#   libGLdispatch; without them Vulkan fails and Chrome silently falls back to SwiftShader (software, ~100x slower).
# - NOT mesa-vulkan-drivers: it adds a software Vulkan driver Chrome could pick instead of the GPU.
# - The NVIDIA container toolkit mounts the driver's graphics libraries and /etc/vulkan/icd.d/nvidia_icd.json
#   (read-only) when the pod has NVIDIA_DRIVER_CAPABILITIES=all (cloudmule sets it). Never write that ICD file.
# The packages (header above, Google Chrome stable included: lib/apt-pass.sh adds Google's signed repository first,
# checking its key's fingerprint) are installed before this runs, in one apt pass with the other modules' on a pod.

# The NVIDIA graphics libraries (driver-matched fallback when the container lacks them): lib/gpu-libs.sh, installed as
# cloudmule-gpu-libs; `cloudmule gpu` runs it again on every graphics pod (a prebuilt image does not have the host's).
install -m 755 "${CM_MODULES_DIR:-/root/cloudmule/modules}/lib/gpu-libs.sh" /usr/local/bin/cloudmule-gpu-libs
cloudmule-gpu-libs

# Chrome's flags that use the GPU (headless), one file per backend. `cloudmule gpu` copies the project's backend to
# /etc/cloudmule/chrome-gpu-flags (GL by default) and exports it to jobs as CLOUDMULE_CHROME_GPU_FLAGS.
# --disable-software-rasterizer: a GPU failure fails instead of going on in software (SwiftShader).
mkdir -p /etc/cloudmule
echo "--headless=new --no-sandbox --ignore-gpu-blocklist --use-gl=angle --use-angle=gl-egl --disable-gpu-watchdog --disable-software-rasterizer" \
  > /etc/cloudmule/chrome-gpu-flags.gl-egl
echo "--headless=new --no-sandbox --use-angle=vulkan --enable-features=Vulkan --disable-vulkan-surface --ignore-gpu-blocklist --disable-software-rasterizer" \
  > /etc/cloudmule/chrome-gpu-flags.vulkan
cp -f /etc/cloudmule/chrome-gpu-flags.gl-egl /etc/cloudmule/chrome-gpu-flags
install -m 755 "${CM_MODULES_DIR:-/root/cloudmule/modules}/lib/webgl-check.py" /usr/local/bin/cloudmule-webgl-check
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
google-chrome --version
