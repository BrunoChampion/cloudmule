# module: ffmpeg — static build of the n8.1 branch from BtbN (linked from ffmpeg.org), sha256 verified.
# Ubuntu 24.04 only ships 6.1. BtbN's dated tags are pruned after a few weeks, so the default is the rolling
# n8.1 asset; to pin one, set FFMPEG_RELEASE=autobuild-… and FFMPEG_ASSET below.
# arch: x86   (BtbN linux64 build; linuxarm64 is not wired in yet)
FFMPEG_RELEASE="${FFMPEG_RELEASE:-latest}"
FFMPEG_ASSET="${FFMPEG_ASSET:-ffmpeg-n8.1-latest-linux64-gpl-8.1.tar.xz}"
cd /tmp
FF_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/$FFMPEG_RELEASE"
curl -fsSLO "$FF_BASE/$FFMPEG_ASSET"
curl -fsSL "$FF_BASE/checksums.sha256" -o ffmpeg-checksums.sha256
grep " $FFMPEG_ASSET\$" ffmpeg-checksums.sha256 | sha256sum -c -
tar -xJf "$FFMPEG_ASSET"
install -m 755 "${FFMPEG_ASSET%.tar.xz}/bin/ffmpeg" "${FFMPEG_ASSET%.tar.xz}/bin/ffprobe" /usr/local/bin/
rm -rf "$FFMPEG_ASSET" "${FFMPEG_ASSET%.tar.xz}" ffmpeg-checksums.sha256
ffmpeg -version | head -1
