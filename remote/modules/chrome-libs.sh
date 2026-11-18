# module: chrome-libs — runtime libraries + fonts for headless Chrome (HyperFrames, Puppeteer, Playwright).
# The browser itself is downloaded by the project's tool (e.g. `playwright install chromium`).
# Ubuntu 24.04 renamed some libraries with a t64 suffix; RunPod's images are 22.04: use whichever name exists.
# arch: x86 arm
apt-get update -q
# t64_name <pkg>: the 24.04 name (<pkg>t64) if this Ubuntu has it, else the old one
t64_name() { if apt-cache show "${1}t64" >/dev/null 2>&1; then echo "${1}t64"; else echo "$1"; fi; }
apt-get install -y -q --no-install-recommends fontconfig fonts-liberation \
  libnss3 libnspr4 "$(t64_name libatk1.0-0)" "$(t64_name libatk-bridge2.0-0)" "$(t64_name libcups2)" libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
  "$(t64_name libasound2)" libdbus-1-3 libxshmfence1 libx11-xcb1 libxcb1 libxext6 libx11-6
