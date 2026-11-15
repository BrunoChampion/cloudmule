# module: base — always installed first. What cloudmule itself needs on the server (Ubuntu 24.04, root):
# the cost guard is Python 3; sync and downloads use tar, rsync and curl.
# arch: x86 arm
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl xz-utils unzip zip git tar rsync jq python3 python-is-python3 build-essential
