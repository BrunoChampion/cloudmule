# module: node@<version> — Node.js from the official tarball (sha256 verified) into /opt/node/<version>, plus
# corepack's pnpm/yarn shims. Versions live side by side, so projects that need different ones don't clash:
# each project's jobs get the version(s) it lists in MODULES first on PATH.
# arch: x86 arm
[ -n "${VERSION:-}" ] || { echo "module node needs a version, e.g. MODULES=\"node@24.15.0\"" >&2; exit 1; }
case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=x64 ;; esac
dir="/opt/node/$VERSION"; tarball="node-v$VERSION-linux-$arch.tar.xz"
cd /tmp
curl -fsSLO "https://nodejs.org/dist/v$VERSION/$tarball"
curl -fsSL "https://nodejs.org/dist/v$VERSION/SHASUMS256.txt" -o node-SHASUMS256.txt
grep " $tarball\$" node-SHASUMS256.txt | sha256sum -c -
rm -rf "$dir"; mkdir -p "$dir"
tar -xJf "$tarball" -C "$dir" --strip-components=1
rm -f "$tarball" node-SHASUMS256.txt
export PATH="$dir/bin:$PATH"
if [ -x "$dir/bin/corepack" ]; then
  corepack enable --install-directory "$dir/bin"
else
  echo "note: Node $VERSION does not bundle corepack; install your package manager in the project's server-setup.sh"
fi
grep -q COREPACK_ENABLE_DOWNLOAD_PROMPT /etc/environment || echo 'COREPACK_ENABLE_DOWNLOAD_PROMPT=0' >> /etc/environment
node --version
