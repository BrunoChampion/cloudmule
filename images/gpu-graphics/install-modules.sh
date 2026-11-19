#!/usr/bin/env bash
# install-modules.sh <module[@version]…> — the image build's copy of what `cloudmule gpu` does on a fresh pod
# (bin/lib.sh: ensure_modules with ONE_APT_PASS=1): one apt pass with every module's "# apt:" packages
# (remote/modules/lib/apt-pass.sh), then each module's own steps, then its marker in /root/cloudmule/mod, so a pod
# started from the image skips them. The module scripts themselves are the repository's: pods and image never drift.
set -euo pipefail
R=/root/cloudmule
M="$R/modules"
export DEBIAN_FRONTEND=noninteractive CM_MODULES_DIR="$M"
pkgs=" "
for spec in "$@"; do
  for p in $(sed -n 's/^# apt:[[:space:]]*//p' "$M/${spec%%@*}.sh"); do
    case "$pkgs" in *" $p "*) ;; *) pkgs="$pkgs$p " ;; esac
  done
done
# shellcheck disable=SC2086   # one word per package (a|b alternatives included)
bash "$M/lib/apt-pass.sh" $pkgs
mkdir -p "$R/mod"
for spec in "$@"; do
  m="${spec%%@*}"; v=""; [ "$spec" = "$m" ] || v="${spec#*@}"
  echo "== module $spec"
  ( export VERSION="$v"; . "$M/$m.sh" )
  touch "$R/mod/$spec"
done
rm -rf /var/lib/apt/lists/* /tmp/*
