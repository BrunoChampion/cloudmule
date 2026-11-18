# module: gpu-graphics — GPU rendering in headless Chrome (WebGL through Vulkan) on a RunPod GPU pod (NVIDIA).
# cloudmule installs it first, on pods of projects with NEEDS_GPU=graphics. It installs the Vulkan/EGL/GL loaders,
# Google Chrome stable (Google's signed apt repository: Google keeps no older versions to pin) and
# `cloudmule-webgl-check`, which prints Chrome's WebGL renderer and fails unless it is the NVIDIA GPU.
# arch: x86
#
# Lessons from the measurements (docs/specs/0004):
# - libglvnd0/libgl1/libegl1 are mandatory: the NVIDIA Vulkan driver (libGLX_nvidia.so.0) needs libglvnd's
#   libGLdispatch; without them Vulkan fails and Chrome silently falls back to SwiftShader (software, ~100x slower).
# - NOT mesa-vulkan-drivers: it adds a software Vulkan driver Chrome could pick instead of the GPU.
# - The NVIDIA container toolkit mounts the driver's graphics libraries and /etc/vulkan/icd.d/nvidia_icd.json
#   (read-only) when the pod has NVIDIA_DRIVER_CAPABILITIES=all (cloudmule sets it). Never write that ICD file.
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl gnupg pciutils \
  libvulkan1 vulkan-tools libglvnd0 libgl1 libegl1 libgles2 fonts-liberation

# Google Chrome stable, from Google's apt repository, signed by Google's Linux package signing key
GOOGLE_FPR=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /tmp/google.pub
gpg --show-keys --with-colons /tmp/google.pub | grep "^fpr:::::::::$GOOGLE_FPR:" >/dev/null \
  || { echo "Google's signing key does not have the expected fingerprint $GOOGLE_FPR" >&2; exit 1; }
gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg /tmp/google.pub
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  > /etc/apt/sources.list.d/google-chrome.list
apt-get update -q
apt-get install -y -q --no-install-recommends google-chrome-stable
rm -f /tmp/google.pub

# Fallback, only if the container got the compute libraries but not the graphics ones: the SAME driver version's
# user-space libraries from NVIDIA's installer (never another version: they must match the kernel module).
LIBDIR=/usr/lib/x86_64-linux-gnu
DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
if [ ! -e "$LIBDIR/libGLX_nvidia.so.0" ] && [ -n "$DRV" ]; then
  echo "libGLX_nvidia.so.0 is missing: adding the graphics libraries of NVIDIA driver $DRV"
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
    ln -sf "libGLX_nvidia.so.$DRV" "$LIBDIR/libGLX_nvidia.so.0"
    ln -sf "libEGL_nvidia.so.$DRV" "$LIBDIR/libEGL_nvidia.so.0"
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

# Chrome's flags that use the GPU (headless): jobs read them from this file
mkdir -p /etc/cloudmule
echo "--headless=new --no-sandbox --use-angle=vulkan --enable-features=Vulkan --disable-vulkan-surface --ignore-gpu-blocklist" \
  > /etc/cloudmule/chrome-gpu-flags
cat > /usr/local/bin/cloudmule-webgl-check <<'CHECK'
#!/usr/bin/env bash
# Prints Chrome's WebGL renderer with the GPU flags; fails unless it is the NVIDIA GPU (a silent software fallback,
# SwiftShader, is ~100x slower and would burn the pod's time cap). Jobs run it before rendering.
set -euo pipefail
page="$(mktemp -d)/webgl.html"
cat > "$page" <<'HTML'
<canvas id="c"></canvas><script>
var g = document.getElementById("c").getContext("webgl"), e = g && g.getExtension("WEBGL_debug_renderer_info");
document.body.textContent = "RENDERER=" + (g ? (e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER)) : "no WebGL");
</script>
HTML
# shellcheck disable=SC2046
r="$(timeout 60 google-chrome $(cat /etc/cloudmule/chrome-gpu-flags) --dump-dom "file://$page" 2>/dev/null \
  | grep -o 'RENDERER=[^<]*' | head -1 | cut -d= -f2-)" || true
echo "WebGL renderer: ${r:-unknown}"
case "$r" in *NVIDIA*) ;; *) echo "ERROR: Chrome is not rendering on the NVIDIA GPU (renderer: ${r:-unknown})" >&2; exit 1 ;; esac
CHECK
chmod +x /usr/local/bin/cloudmule-webgl-check
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' || true
google-chrome --version
