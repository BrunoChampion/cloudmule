# module: base — always installed first. What cloudmule itself needs on the server (Ubuntu 24.04, root):
# the cost guard is Python 3; sync and downloads use tar, rsync and curl.
# Its packages are all in the apt header (installed by lib/apt-pass.sh, in one pass with the other modules' on a pod).
# arch: x86 arm
# apt: ca-certificates curl xz-utils unzip zip git tar rsync jq python3 python-is-python3 build-essential
command -v python3 >/dev/null && command -v rsync >/dev/null && command -v curl >/dev/null
# cloudmule-par: runs a job's independent tasks N at a time (docs/specs/0005; `cloudmule-par --help`)
install -m 755 "${CM_MODULES_DIR:-/root/cloudmule/modules}/lib/cloudmule-par.sh" /usr/local/bin/cloudmule-par
