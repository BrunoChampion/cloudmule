# cloudmule's prebuilt image for GPU pods with NEEDS_GPU=graphics (docs/specs/0005, step b): RunPod's small Ubuntu
# 24.04 image (it authorises PUBLIC_KEY for SSH; no CUDA toolkit: the driver comes from the host) plus the modules a
# graphics pod installs: base, chrome-libs, gpu-graphics (Google Chrome stable, the GL/EGL/Vulkan loaders, the Chrome
# flags, cloudmule-webgl-check), node and ffmpeg. They are installed by the repository's own module scripts, with the
# same safeguards (Google's key fingerprint, checksums), so pods and image never drift apart; Chrome is pinned by the
# image's digest. The NVIDIA driver libraries are NOT baked in: the host's container toolkit mounts them, and
# `cloudmule gpu` still checks them (cloudmule-gpu-libs) and runs cloudmule-webgl-check on every pod.
#
# Built on demand by .github/workflows/gpu-image.yml and pushed to GitHub Container Registry (public). Used by digest:
# RUNPOD_IMAGE_GRAPHICS_DEFAULT in bin/lib.sh, with the hash of what it was built from (images/gpu-graphics/modules-hash.py).
# Rebuild when Chrome needs updating or a module changes (tests/run.sh fails until the recorded hash matches).
FROM runpod/base:1.6.0-ubuntu2404@sha256:2a48fdab5363065169764b7179cd33913f8cabfac7e22afe2955278e6946dc03
ARG NODE_VERSION=24.15.0
COPY remote/modules /root/cloudmule/modules
COPY images/gpu-graphics/install-modules.sh /root/cloudmule/install-modules.sh
RUN bash /root/cloudmule/install-modules.sh base chrome-libs gpu-graphics "node@${NODE_VERSION}" ffmpeg
