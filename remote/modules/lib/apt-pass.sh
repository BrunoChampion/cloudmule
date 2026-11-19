#!/usr/bin/env bash
# apt-pass.sh <package|alternative …>: ONE `apt-get update` and ONE `apt-get install` for the apt packages of the
# modules being installed (their `# apt:` header lines, read by bin/lib.sh). Runs on the server or pod, as root.
#   a|b                    the first of a, b that this Ubuntu has (24.04 renamed some libraries with a t64 suffix;
#                          RunPod's images are 22.04)
#   google-chrome-stable   Google's signed apt repository is added first (its key's fingerprint is checked), so the
#                          one update covers it. Without curl or gpg on the machine, they are installed first (then
#                          there are two updates).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
GOOGLE_FPR=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796   # Google's Linux package signing key

chrome_repo() {
  [ -f /etc/apt/sources.list.d/google-chrome.list ] && return 0
  if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    apt-get update -q
    apt-get install -y -q --no-install-recommends ca-certificates curl gnupg
  fi
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /tmp/google.pub
  gpg --show-keys --with-colons /tmp/google.pub | grep "^fpr:::::::::$GOOGLE_FPR:" >/dev/null \
    || { echo "Google's signing key does not have the expected fingerprint $GOOGLE_FPR" >&2; exit 1; }
  gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg /tmp/google.pub
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    > /etc/apt/sources.list.d/google-chrome.list
  rm -f /tmp/google.pub
}

# CM_APT_MIRROR (set by `cloudmule gpu` on pods): Ubuntu's packages from that official mirror instead of
# archive.ubuntu.com / security.ubuntu.com. Measured 2026-11-19 from RunPod hosts: archive.ubuntu.com at 33 kB/s (an
# apt update took 9-13 min), mirrors.edge.kernel.org at 6.5 MB/s. The packages are the same, signed by Ubuntu (apt
# checks the signatures whatever the mirror). If the update fails there, the original sources come back.
use_mirror() {
  local f; SWITCHED=""
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    [ -f "$f" ] && grep -E 'https?://(archive|security)\.ubuntu\.com/ubuntu' "$f" >/dev/null || continue
    cp -f "$f" "$f.cloudmule-orig"
    sed -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#${CM_APT_MIRROR%/}/#g" "$f.cloudmule-orig" > "$f"
    SWITCHED="$SWITCHED $f"
  done
  [ -z "$SWITCHED" ] || echo "apt: Ubuntu packages from $CM_APT_MIRROR"
}
restore_sources() { local f; for f in $SWITCHED; do mv -f "$f.cloudmule-orig" "$f"; done; SWITCHED=""; }

[ $# -gt 0 ] || exit 0
SWITCHED=""
[ -z "${CM_APT_MIRROR:-}" ] || use_mirror
case " $* " in *" google-chrome-stable "*) chrome_repo ;; esac
if ! apt-get update -q; then
  [ -n "$SWITCHED" ] || exit 1
  echo "apt: the update failed with $CM_APT_MIRROR: back to the original sources" >&2
  restore_sources; apt-get update -q
fi
pkgs=()
for p in "$@"; do
  if [ "${p#*|}" = "$p" ]; then pkgs+=("$p"); continue; fi
  IFS='|' read -ra alts <<< "$p"
  chosen=""
  for a in "${alts[@]}"; do if apt-cache show "$a" >/dev/null 2>&1; then chosen="$a"; break; fi; done
  pkgs+=("${chosen:-${alts[${#alts[@]}-1]}}")
done
echo "apt: installing ${#pkgs[@]} packages: ${pkgs[*]}"
apt-get install -y -q --no-install-recommends "${pkgs[@]}"
