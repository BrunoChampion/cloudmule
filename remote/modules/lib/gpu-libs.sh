#!/usr/bin/env bash
# cloudmule-gpu-libs — the NVIDIA graphics libraries a graphics pod needs (EGL for GL, GLX for Vulkan), added from
# the SAME driver version's installer only if the container got the compute libraries but not the graphics ones.
# Installed by the gpu-graphics module (/usr/local/bin/cloudmule-gpu-libs), which runs it; `cloudmule gpu` runs it
# again at the start of every graphics pod, because a prebuilt image (images/gpu-graphics) has the module but not
# the host's driver: the libraries must match the host's kernel module. A no-op when they are there.
set -u
# Fallback, only if the container got the compute libraries but not the graphics ones: the SAME driver version's
# user-space libraries from NVIDIA's installer (never another version: they must match the kernel module).
LIBDIR=/usr/lib/x86_64-linux-gnu
DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
# Both backends need them: GL/EGL uses libEGL_nvidia and libnvidia-eglcore, Vulkan libGLX_nvidia.
MISSING=""
for lib in libGLX_nvidia.so.0 libEGL_nvidia.so.0 "libnvidia-eglcore.so.$DRV"; do
  [ -e "$LIBDIR/$lib" ] || MISSING="$MISSING $lib"
done
if [ -n "$MISSING" ] && [ -n "$DRV" ]; then
  echo "missing:$MISSING: adding the graphics libraries of NVIDIA driver $DRV"
  rm -f /tmp/nv.run
  # only an installer whose published SHA256 (NVIDIA's .sha256sum next to it) matches is ever run
  for u in "https://us.download.nvidia.com/XFree86/Linux-x86_64/$DRV/NVIDIA-Linux-x86_64-$DRV.run" \
           "https://us.download.nvidia.com/tesla/$DRV/NVIDIA-Linux-x86_64-$DRV.run"; do
    if curl -fsSL -o /tmp/nv.run "$u" && curl -fsSL -o /tmp/nv.sha256 "$u.sha256sum" \
       && [ "$(awk '{print $1}' /tmp/nv.sha256)" = "$(sha256sum /tmp/nv.run | awk '{print $1}')" ]; then break; fi
    rm -f /tmp/nv.run /tmp/nv.sha256
  done
  if [ -s /tmp/nv.run ]; then
    rm -rf /tmp/nv && sh /tmp/nv.run -x --target /tmp/nv >/dev/null
    for lib in libGLX_nvidia libEGL_nvidia libnvidia-glcore libnvidia-eglcore libnvidia-glsi libnvidia-gpucomp \
               libnvidia-glvkspirv libnvidia-tls; do
      f="/tmp/nv/$lib.so.$DRV"
      if [ -e "$f" ] && [ ! -e "$LIBDIR/$lib.so.$DRV" ]; then cp "$f" "$LIBDIR/"; fi
    done
    [ -e "$LIBDIR/libGLX_nvidia.so.0" ] || ln -sf "libGLX_nvidia.so.$DRV" "$LIBDIR/libGLX_nvidia.so.0"
    [ -e "$LIBDIR/libEGL_nvidia.so.0" ] || ln -sf "libEGL_nvidia.so.$DRV" "$LIBDIR/libEGL_nvidia.so.0"
    mkdir -p /usr/share/glvnd/egl_vendor.d
    [ -e /usr/share/glvnd/egl_vendor.d/10_nvidia.json ] \
      || printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}\n' > /usr/share/glvnd/egl_vendor.d/10_nvidia.json
    # the toolkit's ICD file (/etc/vulkan/icd.d, read-only) is never touched: one is written only where none exists
    if [ ! -e /etc/vulkan/icd.d/nvidia_icd.json ] && [ ! -e /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
      mkdir -p /usr/share/vulkan/icd.d
      printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3"}}\n' \
        > /usr/share/vulkan/icd.d/nvidia_icd.json
    fi
    ldconfig
    rm -rf /tmp/nv /tmp/nv.run /tmp/nv.sha256
  else
    echo "WARNING: NVIDIA driver $DRV could not be downloaded with a matching checksum: Chrome may fall back to" \
         "software rendering (cloudmule-webgl-check will tell)" >&2
  fi
fi

