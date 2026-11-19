# module: chrome-libs — runtime libraries + fonts for headless Chrome (HyperFrames, Puppeteer, Playwright).
# The browser itself is downloaded by the project's tool (e.g. `playwright install chromium`).
# All of it is apt packages (header below). Ubuntu 24.04 renamed some libraries with a t64 suffix and RunPod's images
# are 22.04: "a|b" installs whichever this Ubuntu has.
# arch: x86 arm
# apt: fontconfig fonts-liberation libnss3 libnspr4 libatk1.0-0t64|libatk1.0-0 libatk-bridge2.0-0t64|libatk-bridge2.0-0
# apt: libcups2t64|libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1
# apt: libpango-1.0-0 libcairo2 libasound2t64|libasound2 libdbus-1-3 libxshmfence1 libx11-xcb1 libxcb1 libxext6 libx11-6
fc-list >/dev/null
