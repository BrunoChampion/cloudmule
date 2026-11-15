# module: chrome-libs — runtime libraries + fonts for headless Chrome (HyperFrames, Puppeteer, Playwright).
# The browser itself is downloaded by the project's tool (e.g. `playwright install chromium`).
# arch: x86 arm
apt-get update -q
apt-get install -y -q --no-install-recommends fontconfig fonts-liberation \
  libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
  libasound2t64 libdbus-1-3 libxshmfence1 libx11-xcb1 libxcb1 libxext6 libx11-6
