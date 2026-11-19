# cloudmule core library. Sourced by bin/cloudmule; don't run it directly.
# Never print $HCLOUD_TOKEN and never use `set -x` here.
set -euo pipefail

CM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# settings given in the environment win over .env (e.g. IDLE_MINUTES=10 cloudmule start …)
CM_SETTINGS='LOCATIONS|IDLE_MINUTES|SESSION_MAX_HOURS|ONESHOT_IDLE_MINUTES|ONESHOT_MAX_HOURS|BASE_IMAGE|SERVER_NAME|LOG_KEEP_DAYS|USAGE_KEEP_DAYS|RUNPOD_APT_MIRROR'
CM_FROM_ENV="$(env | grep -E "^($CM_SETTINGS)=" || true)"
# RunPod's caps and the standing approval count only from .env: nobody raises them for one command
unset RUNPOD_MAX_USD_PER_HOUR RUNPOD_MAX_MINUTES RUNPOD_MAX_USD_PER_DAY RUNPOD_MAX_USD_PER_MONTH RUNPOD_MAX_PODS \
  RUNPOD_STANDING_APPROVAL
if [ -f "$CM_DIR/.env" ]; then set -a; . "$CM_DIR/.env"; set +a; fi
while IFS= read -r kv; do [ -z "$kv" ] || export "$kv"; done <<< "$CM_FROM_ENV"
if [ -z "${HCLOUD_TOKEN:-}" ] && [ -z "${CM_NO_TOKEN:-}" ]; then   # init/projects/help work without a token
  echo "ERROR: HCLOUD_TOKEN is missing in $CM_DIR/.env (copy .env.example to .env and paste your token there)" >&2
  exit 1
fi
export HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"

# ---------------------------------------------------------------- settings (override in .env)
# No setting chooses the server: the user does, each time it is created (start/oneshot --type), and the choice is
# recorded on Hetzner (last_choice). An old SERVER_TYPES is only reported.
if [ -n "${SERVER_TYPES:-}" ]; then
  echo "NOTE: SERVER_TYPES in $CM_DIR/.env (or the environment) is ignored: the server is chosen with the user" \
       "each time it is created (cloudmule servers). You can delete that line." >&2
fi
unset SERVER_TYPES
LOCATIONS=${LOCATIONS:-"nbg1 fsn1 hel1"}
IDLE_MINUTES=${IDLE_MINUTES:-45}                  # session: snapshot + delete after this long idle
SESSION_MAX_HOURS=${SESSION_MAX_HOURS:-8}
ONESHOT_IDLE_MINUTES=${ONESHOT_IDLE_MINUTES:-20}  # one-shot: delete after this long idle
ONESHOT_MAX_HOURS=${ONESHOT_MAX_HOURS:-3}
BASE_IMAGE=${BASE_IMAGE:-ubuntu-24.04}            # first server ever (no workspace snapshot yet)
SERVER="${SERVER_NAME:-cloudmule}"                # ONE server shared by all your projects
LOG_KEEP_DAYS=${LOG_KEEP_DAYS:-14}                # full job logs in logs/ older than this are deleted
USAGE_KEEP_DAYS=${USAGE_KEEP_DAYS:-90}            # one line per job in logs/usage.tsv, kept this long
USAGE_FILE="$CM_DIR/logs/usage.tsv"
LABEL="managed-by=cloudmule"
WORKSPACE_SEL="role=workspace,scope=shared"
R=/root/cloudmule                                 # cloudmule's own state on the server
# one SSH key per computer; servers get the keys of ALL your computers
SSH_KEY_NAME="cloudmule-$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
KEY="$CM_DIR/keys/id_ed25519"
KNOWN="$CM_DIR/keys/known_hosts"
REGISTRY="$CM_DIR/registry"                       # registry/<project> = that project's folder on this computer
HOME_POINTER="$HOME/.config/cloudmule/home"       # tells the cloudmule skill where this folder is
# RunPod GPU pods (only for work that needs a GPU). The caps are hard limits, enforced in code.
RUNPOD_MAX_USD_PER_HOUR=${RUNPOD_MAX_USD_PER_HOUR:-0.70}   # never create a pod above this price
RUNPOD_MAX_MINUTES=${RUNPOD_MAX_MINUTES:-40}               # every pod is deleted after this long, whatever happens
RUNPOD_MAX_USD_PER_DAY=${RUNPOD_MAX_USD_PER_DAY:-2.00}     # today's spend + the new pod's worst case must stay below
RUNPOD_MAX_USD_PER_MONTH=${RUNPOD_MAX_USD_PER_MONTH:-}     # empty = no monthly cap; else like the daily one, per calendar month
RUNPOD_MAX_PODS=${RUNPOD_MAX_PODS:-}                       # empty = no limit on cloudmule pods running at once
RUNPOD_STANDING_APPROVAL=${RUNPOD_STANDING_APPROVAL:-0}    # 1 = GPU pods may be created without asking each time
# Ubuntu's packages on GPU pods come from this official mirror (empty = the image's own sources): archive.ubuntu.com
# answered RunPod's hosts at 33 kB/s on 2026-11-19 (an apt update took 9-13 min); same packages, signed by Ubuntu
RUNPOD_APT_MIRROR=${RUNPOD_APT_MIRROR-https://mirrors.edge.kernel.org/ubuntu}
RUNPOD_BOOT_SECONDS=${RUNPOD_BOOT_SECONDS:-600}            # from creation, no SSH after this long: NO_PUBLIC_SSH, deleted (an image's first pull on a host can take minutes)
RUNPOD_POLL_SECONDS=${RUNPOD_POLL_SECONDS:-10}
RUNPOD_IMAGE_DEFAULT="runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04"   # cuda: SSH preconfigured, CUDA 11.8
# graphics: the prebuilt image (images/gpu-graphics: Chrome, GL/EGL, Node 24.15.0, ffmpeg; pods skip those installs).
# Measured 2026-11-19 on an A40: SSH after 36 s, modules 2 s (from the PyTorch image: ~45-60 s and 2-5 min of installs).
RUNPOD_IMAGE_GRAPHICS_DEFAULT="ghcr.io/brunochampion/cloudmule-gpu-graphics@sha256:133b28e4d0db180a29aafe6d5de4a0e1b7cdcbaaeb7f13d1a71418b5cd578e9a"   # gpu-image-2026-11-19
# with a prebuilt image: the hash of what it was built from (images/gpu-graphics/modules-hash.py), from the build's
# job summary. tests/run.sh fails when remote/modules or images/gpu-graphics changed since: rebuild the image.
RUNPOD_IMAGE_GRAPHICS_SOURCE="f098a23bd0ee45cd"
POD_RECORDS="$CM_DIR/logs/runpod"                        # one record per GPU pod this computer created, until it is deleted
LAST_GPU_FILE="$CM_DIR/logs/last-gpu"             # the user's last GPU choice: gpu, cloud, project, date (tabs)
USAGE_SINK=""                                     # set only by `gpu` (see usage_sink)
mkdir -p "$CM_DIR/keys" "$CM_DIR/logs" "$REGISTRY"

die() { echo "ERROR: $*" >&2; exit 1; }

hc() {
  if command -v hcloud >/dev/null 2>&1; then hcloud "$@"; return; fi
  local win="${LOCALAPPDATA:-}/Microsoft/WinGet/Packages/HetznerCloud.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe/hcloud.exe"
  if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1 && [ -x "$(cygpath -u "$win")" ]; then
    "$(cygpath -u "$win")" "$@"; return
  fi
  die "the Hetzner CLI 'hcloud' is not installed (see README: Requirements)"
}
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then PY=python3; else PY=python; fi
tools() { "$PY" -I "$CM_DIR/bin/tools.py" "$@"; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
sha12() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-12; }

SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o ConnectTimeout=10 -o LogLevel=ERROR)
IP=""

write_home_pointer() { mkdir -p "$(dirname "$HOME_POINTER")"; printf '%s\n' "$CM_DIR" > "$HOME_POINTER"; }

# ---------------------------------------------------------------- projects
# A project lives wherever its owner wants. Its cloudmule settings are the folder <project>/.cloudmule/
# (config.sh, jobs/, optional server-setup.sh and CLAUDE.md; never secrets), created by `cloudmule init`, which
# also registers the project on this computer (registry/<name>, not versioned).
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
project_names() { ls "$REGISTRY" 2>/dev/null | tr '\n' ' '; }

# project_paths <name>: sets PROJECT_ROOT (the project's folder) and PROJECT_DIR (its .cloudmule/); 1 if unknown
project_paths() {
  [ -f "$REGISTRY/$1" ] || return 1
  PROJECT_ROOT="$(cat "$REGISTRY/$1")"; PROJECT_DIR="$PROJECT_ROOT/.cloudmule"
}

# job_script <job>: the path of the project's .cloudmule/jobs/<job>.sh (dies listing the jobs if there is none)
job_script() {
  [ -f "$PROJECT_DIR/jobs/$1.sh" ] \
    || die "no job '$1' ($PROJECT_DIR/jobs/$1.sh). Jobs: $(ls "$PROJECT_DIR/jobs" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')"
  printf '%s' "$PROJECT_DIR/jobs/$1.sh"
}

# config_name <config.sh>: the PROJECT_NAME it declares
config_name() { grep -E '^PROJECT_NAME=' "$1" | head -1 | sed -E "s/^PROJECT_NAME=[\"']?([a-z0-9-]*).*/\\1/"; }

# check_no_secrets: .cloudmule/ may be committed with the project (even to a public repo): no secrets allowed
check_no_secrets() {
  local bad
  bad="$(find "$PROJECT_DIR" -type f \( -name '.env*' -o -name '*.pem' -o -name '*.key' -o -name 'id_*' \) 2>/dev/null)"
  bad="$bad$(grep -rlE '^[[:space:]]*(export[[:space:]]+)?(HCLOUD_TOKEN|RUNPOD_API_KEY)=' "$PROJECT_DIR" 2>/dev/null || true)"
  [ -z "$bad" ] || die "$PROJECT_DIR contains files that look like secrets; move them out:
$bad
(the Hetzner token and the RunPod key belong only in $CM_DIR/.env; the project's own secrets stay where the
project keeps them)"
}

# load_project <name> [target]: reads the project's .cloudmule/config.sh. A project with NEEDS_TARGET=1 (one
# sub-folder per piece of work, e.g. per video) takes a target, available to the config as $TARGET.
load_project() {
  PROJECT="${1:?missing project}"; TARGET="${2:-}"
  valid_name "$PROJECT" || die "invalid project name '$PROJECT' (lowercase letters, digits and dashes)"
  project_paths "$PROJECT" || die "unknown project '$PROJECT' on this computer. Projects: $(project_names)
(to add one, run in its folder: cloudmule init)"
  [ -f "$PROJECT_DIR/config.sh" ] || die "missing $PROJECT_DIR/config.sh (was the project moved? run cloudmule init in its folder)"
  check_no_secrets
  NEEDS_TARGET=0; LOCAL_DIR=""; REMOTE_DIR=""; MODULES=""; SYNC_EXCLUDE=""; SYNC_SEEDS=""; ONESHOT_EXCLUDE=""
  INSTALL_CMD=""; INSTALL_TRIGGERS=""; INSTALL_CHECK=""; PROJECT_NAME=""
  MIN_RAM_GB=""; MIN_CPUS=""; MIN_DISK_GB=""
  NEEDS_GPU=""; MIN_VRAM_GB=""; RUNPOD_IMAGE=""   # GPU work (RunPod pods): empty NEEDS_GPU = the project did not say
  GPU_SELFTEST=""; GPU_GRAPHICS_BACKEND=""        # a job that must pass before the real one; graphics: gl-egl or vulkan
  local SERVER_TYPES=""   # only to notice an old setting in config.sh
  . "$PROJECT_DIR/config.sh"
  [ -z "$SERVER_TYPES" ] || echo "NOTE: SERVER_TYPES in $PROJECT_DIR/config.sh is ignored: the server is chosen with" \
    "the user each time it is created (cloudmule servers). You can delete that line." >&2
  if [ "$NEEDS_TARGET" = 1 ]; then
    [ -n "$TARGET" ] || die "project '$PROJECT' needs a target (e.g. ${TARGET_EXAMPLE:-<target>})"
    [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid target '$TARGET'"
    . "$PROJECT_DIR/config.sh"   # re-read so $TARGET expands
  fi
  [ "$PROJECT_NAME" = "$PROJECT" ] || die "$PROJECT_DIR/config.sh says PROJECT_NAME=$PROJECT_NAME, not '$PROJECT'"
  LOCAL_DIR="${LOCAL_DIR:-$PROJECT_ROOT}"
  REMOTE_DIR="${REMOTE_DIR:-/root/work/$PROJECT${TARGET:+/$TARGET}}"
  case "$REMOTE_DIR" in "/root/work/$PROJECT"|"/root/work/$PROJECT/"*) ;;
    *) die "REMOTE_DIR must be under /root/work/$PROJECT/ (the server is shared by your projects)" ;; esac
  [ -d "$LOCAL_DIR" ] || die "local folder does not exist: $LOCAL_DIR"
  local spec
  for spec in $MODULES; do
    [[ "${spec%%@*}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -f "$CM_DIR/remote/modules/${spec%%@*}.sh" ] \
      || die "unknown module '${spec%%@*}' in MODULES. Available: $(ls "$CM_DIR/remote/modules" | sed -n 's/\.sh$//p' | tr '\n' ' ')"
  done
  # settings and results never need uploading; .cloudmule/files/ goes on its own to .cloudmule-files (sync_project)
  SYNC_EXCLUDE="$SYNC_EXCLUDE .cloudmule .cloudmule-out .cloudmule-files"
  # what the server must offer this project (defaults are safe for small projects)
  RAM_SRC=config; [ -n "$MIN_RAM_GB" ] || { MIN_RAM_GB=4; RAM_SRC=default; }
  CPUS_SRC=config; [ -n "$MIN_CPUS" ] || { MIN_CPUS=2; CPUS_SRC=default; }
  DISK_SRC=config; [ -n "$MIN_DISK_GB" ] || { MIN_DISK_GB=40; DISK_SRC=default; }
  case "$NEEDS_GPU" in ""|0|graphics|cuda) ;; *) die "NEEDS_GPU in $PROJECT_DIR/config.sh must be 0, graphics or cuda" ;; esac
  VRAM_SRC=config; [ -n "$MIN_VRAM_GB" ] || { MIN_VRAM_GB=8; VRAM_SRC=default; }
  case "${GPU_GRAPHICS_BACKEND:-gl-egl}" in gl-egl|vulkan) ;;
    *) die "GPU_GRAPHICS_BACKEND in $PROJECT_DIR/config.sh must be gl-egl (the default) or vulkan" ;; esac
  GPU_GRAPHICS_BACKEND="${GPU_GRAPHICS_BACKEND:-gl-egl}"
  [ -z "$GPU_SELFTEST" ] || [[ "$GPU_SELFTEST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "GPU_SELFTEST in $PROJECT_DIR/config.sh must be the name of a job in jobs/ (without .sh)"
  PROJECT_ARCHS="$(module_archs base $MODULES)"
  LEASE="$PROJECT${TARGET:+--$TARGET}"   # this project's claim on the shared server
  # versioned modules (node@24.15.0) live in /opt/<module>/<version>: put this project's versions first on PATH
  JOB_ENV="export PATH=$(for spec in $MODULES; do [[ "$spec" != *@* ]] || printf '/opt/%s/%s/bin:' "${spec%%@*}" "${spec#*@}"; done)\$PATH"
  # .cloudmule/files/ (helpers and reference data shared by the project's jobs), uploaded next to the project
  JOB_ENV="$JOB_ENV CLOUDMULE_FILES=$REMOTE_DIR/.cloudmule-files"
}

# ---------------------------------------------------------------- servers
server_exists() {
  local names
  names="$(hc server list -l "$LABEL" -o noheader -o columns=name)" \
    || die "could not talk to the Hetzner API (check HCLOUD_TOKEN in $CM_DIR/.env)"
  printf '%s\n' "$names" | grep -x "$1" >/dev/null
}

need_server() {
  server_exists "$SERVER" || die "the server '$SERVER' is not running (start it with: cloudmule start ${PROJECT:-<project>} ${TARGET:-})"
  IP="$(hc server ip "$SERVER")"
}

rsh() { ssh "${SSH_OPTS[@]}" "root@$IP" "$@"; }
rsh_tty() { ssh -t "${SSH_OPTS[@]}" "root@$IP" "$@"; }

# wait_ssh [seconds]: waits until the server (or a GPU pod) answers over SSH, for at most about <seconds> (180)
wait_ssh() {
  local limit="${1:-180}" t0; t0=$(date +%s)
  until rsh true 2>/dev/null; do
    if [ $(( $(date +%s) - t0 )) -ge "$limit" ]; then
      echo "ERROR: no answer over SSH within $limit s" >&2
      return 1
    fi
    sleep 3
  done
}

forget_host() { [ -f "$KNOWN" ] && ssh-keygen -f "$KNOWN" -R "$1" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- choosing the server
# module_archs <module…>: CPU architectures every given module supports (header line "# arch: x86 arm";
# a module without it is assumed x86-only)
module_archs() {
  local archs="x86 arm" m a x keep
  for m in "$@"; do
    a="$(sed -n 's/^# arch:[[:space:]]*//p' "$CM_DIR/remote/modules/${m%%@*}.sh" | head -1 | sed 's/(.*//')"
    keep=""; for x in $archs; do case " ${a:-x86} " in *" $x "*) keep="$keep $x" ;; esac; done
    archs="${keep# }"
  done
  printf '%s' "$archs"
}

# no_project_reqs: requirements when no project is given (only the saved workspace limits the choice)
no_project_reqs() {
  MIN_RAM_GB=0; MIN_CPUS=0; MIN_DISK_GB=0; PROJECT_ARCHS="x86 arm"
  RAM_SRC=none; CPUS_SRC=none; DISK_SRC=none
}

# workspace_info [--fresh]: WS_IMAGE/WS_DISK/WS_ARCH of the saved workspace snapshot (empty if none or --fresh).
# A snapshot only restores on a server whose disk is at least the disk it was taken from.
workspace_info() {
  WS_IMAGE=""; WS_DISK=""; WS_ARCH=""
  [ "${1:-}" = --fresh ] && return 0
  WS_IMAGE="$(latest_image "$WORKSPACE_SEL")"
  [ -n "$WS_IMAGE" ] || return 0
  read -r WS_DISK WS_ARCH <<< "$(hc image describe "$WS_IMAGE" -o json | tools image-info)"
}

# reqs_args: the requirement options for tools.py (menu / candidates / below), into REQS
reqs_args() {
  REQS=(--locations "${CHOSEN_LOCATION:-$LOCATIONS}" --min-ram "$MIN_RAM_GB" --min-cpus "$MIN_CPUS"
        --min-disk "$MIN_DISK_GB" --archs "$PROJECT_ARCHS" --workspace-disk "${WS_DISK:-0}" --workspace-arch "${WS_ARCH:-}")
}

# choose_candidates: "type location eur" lines to try for CHOSEN_TYPE (the user's choice), cheapest location
# first; refused if it does not fit the project and the saved workspace
choose_candidates() {
  reqs_args
  CANDS="$(hc server-type list -o json | tools candidates --types "$CHOSEN_TYPE" "${REQS[@]}")" \
    || die "$CHOSEN_TYPE cannot be used now (reason above). See the options: cloudmule servers ${PROJECT:-}${TARGET:+ $TARGET}"
}

# ---------------------------------------------------------------- the user's server choice (labels on Hetzner)
# The server is created with chosen-type / chosen-by / chosen-at labels, and the workspace snapshot copies them,
# so every agent of every project and computer sees the last choice, with the server running or not.
# choice_labels: CHOICE_LABELS for a server created now with CHOSEN_TYPE for PROJECT (values Hetzner accepts)
choice_labels() {
  # Hetzner label values: up to 63 of [A-Za-z0-9._-], alphanumeric at both ends
  local by; by="$(printf '%s' "${PROJECT:-none}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-63 \
    | sed -e 's/^[^A-Za-z0-9]*//' -e 's/[^A-Za-z0-9]*$//')"
  by="${by:-unknown}"
  CHOICE_LABELS=("chosen-type=$CHOSEN_TYPE" "chosen-by=$by" "chosen-at=$(date +%Y-%m-%d)")
}

# last_choice [--type]: "<type> (by <project>, <date>)" (or only the type) from the running server, else from the
# saved workspace; "none yet" (empty with --type) when neither carries the labels
last_choice() {
  local json="" img
  if server_exists "$SERVER"; then json="$(hc server describe "$SERVER" -o json)"
  else img="$(latest_image "$WORKSPACE_SEL")"; [ -z "$img" ] || json="$(hc image describe "$img" -o json)"; fi
  if [ -z "$json" ]; then [ "${1:-}" = --type ] || echo "none yet"; return 0; fi
  printf '%s' "$json" | tools choice ${1:+"$1"}
}

# create_server <name> <candidates> <image> <label...>: tries each "type location eur" line in order
create_server() {
  local name="$1" cands="$2" img="$3"; shift 3
  local labels=(--label "$LABEL"); local l; for l in "$@"; do labels+=(--label "$l"); done
  local t loc eur k keys=()
  for k in $(hc ssh-key list -l "$LABEL" -o noheader -o columns=name); do keys+=(--ssh-key "$k"); done
  [ ${#keys[@]} -gt 0 ] || die "no SSH keys registered: run 'cloudmule setup' on this computer"
  while read -r t loc eur; do
    echo "Creating $name ($t, $eur EUR/h incl. VAT) in $loc from image $img…"
    if hc server create --name "$name" --type "$t" --image "$img" --location "$loc" \
         "${keys[@]}" "${labels[@]}" >/dev/null; then
      IP="$(hc server ip "$name")"; forget_host "$IP"
      return 0
    fi
    # another session may have created it meanwhile: join it instead of failing
    if server_exists "$name"; then echo "Another session created $name meanwhile: joining it."; IP="$(hc server ip "$name")"; return 0; fi
  done <<< "$cands"
  die "could not create the server with any of: $(echo $cands)"
}

delete_server() {
  local name="$1" ip
  server_exists "$name" || return 0
  ip="$(hc server ip "$name")"
  hc server delete "$name" >/dev/null
  forget_host "$ip"
  echo "Server $name deleted."
}

# ---------------------------------------------------------------- images (snapshots)
image_ids() { hc image list -t snapshot -l "$LABEL,$1" -o noheader -o columns=id | sort -n | tr -d ' '; }
latest_image() { image_ids "$1" | tail -1; }
prune_images() {   # keep only the newest snapshot matching the selector
  local ids id; ids="$(image_ids "$1" | sed '$d')"
  for id in $ids; do echo "Deleting old snapshot $id ($1)"; hc image delete "$id" >/dev/null; done
}

# ---------------------------------------------------------------- leases (who is using the shared server)
# A lease = "this project/target is using the server". Every command of a project refreshes its lease (the file's
# mtime), so a lease untouched for long with no job running is probably stale (its session ended without `end`).
# lease_add also tells the cost guard "in use now": it only looks every 5 minutes, and short commands between
# two looks would otherwise not count as activity.
lease_add() {
  rsh "mkdir -p $R/leases && echo '$PROJECT ${TARGET:-} $(hostname) $(date -u +%FT%TZ)' > $R/leases/$LEASE \
       && { [ ! -d /run/cloudmule ] || date +%s > /run/cloudmule/last_active; }"
}
lease_drop() { rsh "rm -f $R/leases/$LEASE" 2>/dev/null || true; }
leases() { rsh "ls $R/leases 2>/dev/null" 2>/dev/null || true; }
# leases_report: one line per lease: name, minutes since last use, and jobs of that project running now
leases_report() {
  rsh "now=\$(date +%s); for f in $R/leases/*; do [ -e \"\$f\" ] || continue; n=\$(basename \"\$f\");
         age=\$(( (now - \$(stat -c %Y \"\$f\")) / 60 )); jobs=\$(pgrep -af \"$R/jobs/\$n-\" | grep -v pgrep | grep -o \"$R/jobs/\$n-[^ ]*\\.log\" | sort -u | wc -l);
         echo \"  \$n: last used \${age} min ago, jobs running: \$jobs  (\$(cat \"\$f\"))\"; done" 2>/dev/null || true
}

# ---------------------------------------------------------------- modules (what the server needs installed)
# module_apt <module…>: the apt packages the modules declare (their "# apt:" header lines), each once, in order;
# "a|b" = whichever this Ubuntu has (resolved on the machine by lib/apt-pass.sh)
module_apt() {
  local m p out=" "
  for m in "$@"; do
    for p in $(sed -n 's/^# apt:[[:space:]]*//p' "$CM_DIR/remote/modules/${m%%@*}.sh"); do
      case "$out" in *" $p "*) ;; *) out="$out$p " ;; esac
    done
  done
  out="${out# }"; printf '%s' "${out% }"
}

# quoted <words…>: the words quoted for a remote shell ("a|b" must not become a pipe)
quoted() { local w out=""; for w in "$@"; do out="$out $(printf '%q' "$w")"; done; printf '%s' "${out# }"; }

# ensure_modules: install on the running server every module of this project it does not have yet (markers
# $R/mod/<module>[@version]). They persist in the shared workspace snapshot, so each one installs once.
# Shared server: module by module, each one's apt packages (lib/apt-pass.sh) then its own steps. GPU pod
# (ONE_APT_PASS=1): ONE apt pass for every missing module's packages first, with the modules that only download
# (no apt packages: node, ffmpeg) running beside it when curl and xz are there; then each module's own steps.
# MODULE_TIMES: "apt=<s> <module>=<s> …" (seconds, for the PHASES line).
ensure_modules() {
  local spec m v missing pkgs apt early="" t0
  MODULE_TIMES=""
  # base again where cloudmule-par is missing (a workspace saved before base installed it)
  missing="$(rsh "for s in base $MODULES; do test -f $R/mod/\$s || printf ' %s' \"\$s\"; done; \
    test -x /usr/local/bin/cloudmule-par || test ! -f $R/mod/base || printf ' base'")"
  [ -n "$missing" ] || return 0
  echo "== Installing on the server:$missing =="
  tar cf - --exclude=__pycache__ -C "$CM_DIR/remote" modules | rsh "mkdir -p $R && rm -rf $R/modules && tar --no-same-owner -xf - -C $R"
  if [ "${ONE_APT_PASS:-0}" = 1 ]; then
    pkgs="$(module_apt $missing)"
    for spec in $missing; do [ "${spec%%@*}" = base ] || [ -n "$(module_apt "$spec")" ] || early="$early $spec"; done
    t0=$(date +%s)
    remote_job "$LEASE-modules-apt" /root "$(apt_pass_cmd "$pkgs" "$early")"
    MODULE_TIMES="apt=$(( $(date +%s) - t0 ))"
    missing="$(rsh "for s in $missing; do test -f $R/mod/\$s || printf ' %s' \"\$s\"; done; \
      test -x /usr/local/bin/cloudmule-par || printf ' base'")"
  fi
  for spec in $missing; do
    m="${spec%%@*}"; v=""; [ "$spec" = "$m" ] || v="${spec#*@}"
    apt=""; [ "${ONE_APT_PASS:-0}" = 1 ] || apt="$(module_apt "$spec")"
    t0=$(date +%s)
    remote_job "$LEASE-module-$m" /root "set -euo pipefail; export DEBIAN_FRONTEND=noninteractive CM_MODULES_DIR=$R/modules VERSION=$(printf '%q' "$v"); \
      ${apt:+bash $R/modules/lib/apt-pass.sh $(quoted $apt) && }. $R/modules/$m.sh && mkdir -p $R/mod && touch $R/mod/$spec"
    MODULE_TIMES="$MODULE_TIMES $m=$(( $(date +%s) - t0 ))"
  done
  MODULE_TIMES="${MODULE_TIMES# }"
}

# apt_pass_cmd <packages> <download-only modules>: the remote command of a pod's one apt pass. The download-only
# modules run beside it (each marks itself done); a module that fails there just runs again after it, in order.
apt_pass_cmd() {
  local spec m v cmd="set -u; export DEBIAN_FRONTEND=noninteractive CM_MODULES_DIR=$R/modules CM_APT_MIRROR=$(printf '%q' "$RUNPOD_APT_MIRROR"); mkdir -p $R/mod; "
  if [ -n "$2" ]; then
    # one after another, beside the apt pass (two versions of one module would share its download's temp files)
    cmd="${cmd}if command -v curl >/dev/null && command -v xz >/dev/null; then { "
    for spec in $2; do
      m="${spec%%@*}"; v=""; [ "$spec" = "$m" ] || v="${spec#*@}"
      cmd="$cmd( set -euo pipefail; export VERSION=$(printf '%q' "$v"); . $R/modules/$m.sh ) > $R/jobs/early-${spec//@/-}.out 2>&1 && touch $R/mod/$spec; "
    done
    cmd="${cmd}} & fi; "
  fi
  printf '%s' "${cmd}bash $R/modules/lib/apt-pass.sh $(quoted $1); rc=\$?; wait; \
for f in $R/jobs/early-*.out; do [ -e \"\$f\" ] && { echo \"== \$f\"; tail -n 3 \"\$f\"; }; done; exit \$rc"
}

# server_setup: runs the project's .cloudmule/server-setup.sh once per server (again when the file changes);
# its result persists in the workspace snapshot.
server_setup() {
  local s="$PROJECT_DIR/server-setup.sh" h
  [ -f "$s" ] || return 0
  h="$(sha12 "$s")"
  rsh "test -f $R/setup/$PROJECT-$h" && return 0
  echo "== server-setup.sh of $PROJECT =="
  rsh "mkdir -p $R/scripts && cat > $R/scripts/setup-$PROJECT.sh" < "$s"
  remote_job "$PROJECT-setup" /root "bash $R/scripts/setup-$PROJECT.sh && mkdir -p $R/setup && touch $R/setup/$PROJECT-$h"
}

# ---------------------------------------------------------------- cost guard
# arm_guard <mode oneshot|session> <idle_min> <max_h>: token to the RAM disk (/run, never in a snapshot) and a
# systemd timer running remote/guard.py every 5 min. In session mode the guard snapshots before deleting.
arm_guard() {
  local mode="$1" idle="$2" maxh="$3" sid
  local sj; sj="$(hc server describe "$SERVER" -o json)"
  sid="$(printf '%s' "$sj" | tools field id)"
  printf '%s' "$HCLOUD_TOKEN" | rsh 'umask 077; mkdir -p /run/cloudmule; cat > /run/cloudmule/token'
  # the server type, for every job's usage line (RAM disk: a restored workspace may run on another type)
  local stype; stype="$(printf '%s' "$sj" | tools server-type | cut -d, -f1)" || true
  rsh "echo ${stype:-unknown} > /run/cloudmule/server-type"
  rsh 'cat > /run/cloudmule/guard.py' < "$CM_DIR/remote/guard.py"
  rsh "systemctl stop cloudmule-guard.timer cloudmule-guard.service >/dev/null 2>&1; \
       systemctl reset-failed cloudmule-guard.timer cloudmule-guard.service >/dev/null 2>&1; \
       date +%s > /run/cloudmule/last_active; \
       systemd-run --quiet --unit cloudmule-guard --on-active=5min --on-unit-active=5min \
       /usr/bin/python3 /run/cloudmule/guard.py $sid $mode $idle $maxh"
  echo "Cost guard armed: the server deletes itself after ${idle} min idle or ${maxh} h up (mode $mode)."
}

# ---------------------------------------------------------------- remote jobs
# MEASURE runs on the server right after a job, inside the job's own cgroup, and prints one measurement line of
# key=value pairs (read by `tools usage-add`; a missing or empty value counts as n/a). The kernel keeps the
# cgroup's peak RAM (memory.peak, file cache included), CPU time (cpu.stat) and the time its tasks stalled for
# lack of memory (memory.pressure, "some" total): nothing is sampled.
MEASURE='pk=; cu=; pr=
if [ "${CM_SCOPED:-}" = 1 ]; then
  cg=/sys/fs/cgroup$(sed -n "s/^0:://p" /proc/self/cgroup)
  pk=$(cat $cg/memory.peak 2>/dev/null); cu=$(awk "/^usage_usec/{print \$2}" $cg/cpu.stat 2>/dev/null)
  pr=$(sed -n "s/^some .*total=//p" $cg/memory.pressure 2>/dev/null)
fi
echo "start=$s end=$(date +%s) exit=$rc peak_bytes=$pk cpu_usec=$cu stall_usec=$pr" \
  "type=$(cat /run/cloudmule/server-type 2>/dev/null) vcpus=$(nproc) mem_kb=$(awk "/^MemTotal/{print \$2}" /proc/meminfo)"'

# remote_job <name> <remote_dir> <command>: runs detached from SSH (survives a dropped connection or this computer
# killing the local process), follows it and saves the log in logs/. Returns the command's success.
remote_job() {
  local name="$1" dir="$2" cmd="$3" log="$R/jobs/$1.log" use="$R/jobs/$1.usage" inner q launch
  # ( … ) so the log captures every command of a chain, and an `exit` or `set -e` inside the command cannot skip
  # the EXIT line. The measurement is written before the EXIT line, which tells remote_wait the job is over.
  # $log.pid: this wrapper's pid, so the job's process group can be stopped before a GPU pod's time cap (stop_job);
  # the wrapper itself survives that TERM (a no-op trap, reset in the job's subshell) to write the EXIT line.
  inner="touch $log.run; echo \$\$ > $log.pid; trap : TERM; s=\$(date +%s); ( $cmd ) > $log 2>&1; rc=\$?
         { $MEASURE; } > $use 2>/dev/null; echo \"EXIT \$rc\" >> $log"
  q="$(printf '%q' "$inner")"
  # its own cgroup (a transient systemd scope) is what makes it measurable; if the scope cannot be created the
  # job runs unmeasured. The job marks its start ($log.run) first thing, so a job that started (and then ended
  # or was stopped) never runs twice.
  launch="if command -v systemd-run >/dev/null 2>&1; then
    CM_SCOPED=1 systemd-run --scope --quiet --collect bash -c $q || { test -f $log.run || bash -c $q; }
  else bash -c $q; fi"
  # only the job goes to the background ({ … & }), fully detached, so this SSH call returns at once
  # an uncollected measurement of the previous run (local process killed, no attach) is kept as .prev
  # the log exists before the job starts, so remote_wait never misses a job that is still starting
  rsh "mkdir -p $R/jobs && rm -f $log.run && : > $log && { [ ! -f $use ] || mv -f $use $use.prev; } && cd '$dir' && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 CI=true && \
       { nohup setsid -f bash -c $(printf '%q' "$launch") >/dev/null 2>&1 < /dev/null & }"
  remote_wait "$name"
}

# usage_sink <remote job name>: stores the measurement lines on stdin as usage lines. A GPU pod sets USAGE_SINK
# instead (a file, or /dev/null for its setup jobs): its one usage line, with the cost, is written when the pod is
# deleted.
usage_sink() {
  if [ -n "${USAGE_SINK:-}" ]; then cat >> "$USAGE_SINK"
  else tools usage-add "$(winpath "$USAGE_FILE")" "$USAGE_KEEP_DAYS" "${PROJECT:--}" "${TARGET:-}" "$(job_label "$1")"; fi
}

# job_label <remote job name>: the job's name without its lease or project prefix (for its usage line)
job_label() {
  local n="$1"
  if [ -n "${LEASE:-}" ] && [ "${n#"$LEASE-"}" != "$n" ]; then echo "${n#"$LEASE-"}"
  elif [ -n "${PROJECT:-}" ]; then echo "${n#"$PROJECT-"}"
  else echo "$n"; fi
}

# stop_job <name>: sends TERM to a running remote job's process group (the job and everything it started)
stop_job() {   # (only while its wrapper, a bash, is alive: a reused pid is never signalled)
  rsh "p=\$(cat $R/jobs/$1.log.pid 2>/dev/null) && [ \"\$(cat /proc/\$p/comm 2>/dev/null)\" = bash ] \
       && g=\$(awk '{print \$5}' /proc/\$p/stat 2>/dev/null) && [ -n \"\$g\" ] && kill -TERM -- -\$g" 2>/dev/null || true
}

# remote_wait <name>: follow (or re-attach to) a remote job until it ends; it looks after 2 s, then twice as long each
# time up to every 20 s (CM_POLL_SECONDS), so short steps (a module, a check) do not wait a whole 20 s.
# With WAIT_DEADLINE (epoch seconds, set by `gpu` before a pod's time cap): at that moment the job gets TERM and up to
# STOP_GRACE seconds (60) to end; then the wait ends either way, with STOPPED_AT_DEADLINE=1.
WAIT_DEADLINE=""; STOP_GRACE=60; STOPPED_AT_DEADLINE=0
remote_wait() {
  local name="$1" log="$R/jobs/$1.log" start last cap="${CM_POLL_SECONDS:-20}" every=2 termed="" lost=0
  [ "$every" -le "$cap" ] || every="$cap"
  rsh "test -f $log" || { echo "ERROR: there is no job '$name' on the server" >&2; return 1; }
  start=$(date +%s); last=""
  while true; do
    last="$(rsh "tail -c 4000 $log 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -1" 2>/dev/null || echo '(no connection, retrying)')"
    case "$last" in "EXIT "*) break ;; esac
    # no answer 15 times in a row (the machine is gone, e.g. a pod deleted at its cap): stop waiting
    case "$last" in "(no connection"*) lost=$((lost + 1)) ;; *) lost=0 ;; esac
    [ "$lost" -lt 15 ] || { last="EXIT no answer from the machine (15 tries)"; break; }
    echo "[$name $(( ($(date +%s) - start) / 60 )) min] $last"
    if [ -n "$WAIT_DEADLINE" ] && [ -z "$termed" ] && [ "$(date +%s)" -ge "$WAIT_DEADLINE" ]; then
      echo "DEADLINE: the pod's time cap is near: stopping '$name' (TERM) and keeping what it has announced so far"
      stop_job "$name"; termed=$(date +%s); STOPPED_AT_DEADLINE=1
    fi
    if [ -n "$termed" ] && [ $(( $(date +%s) - termed )) -ge "$STOP_GRACE" ]; then
      last="EXIT stopped at the deadline (no EXIT line after ${STOP_GRACE} s)"; break
    fi
    if [ -n "$termed" ]; then sleep 2
    elif [ -n "$WAIT_DEADLINE" ] && [ $(( WAIT_DEADLINE - $(date +%s) )) -lt "$every" ]; then
      sleep $(( WAIT_DEADLINE - $(date +%s) > 0 ? WAIT_DEADLINE - $(date +%s) : 1 ))
    else sleep "$every"; every=$(( every * 2 < cap ? every * 2 : cap )); fi
  done
  LAST_LOG="$CM_DIR/logs/$name-$(date +%Y%m%d-%H%M).log"
  rsh "[ ! -d /run/cloudmule ] || date +%s > /run/cloudmule/last_active" 2>/dev/null || true   # a job just ended: in use
  rsh "cat $log" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' > "$LAST_LOG" || true
  # the job's measurements (this run, and an uncollected previous one) into logs/usage.tsv, each exactly once:
  # `mv` is atomic, so of a `job` and an `attach` collecting at the same moment only one gets the file
  rsh "for f in $R/jobs/$name.usage.prev $R/jobs/$name.usage; do
         mv \"\$f\" \"\$f.\$\$\" 2>/dev/null && cat \"\$f.\$\$\" && rm -f \"\$f.\$\$\"; done; true" 2>/dev/null \
    | usage_sink "$name" || true
  tools prune-logs "$(winpath "$CM_DIR/logs")" "$LOG_KEEP_DAYS" || true
  if [ "$last" != "EXIT 0" ]; then
    echo "ERROR: '$name' failed ($last). Log: $LAST_LOG" >&2
    tail -20 "$LAST_LOG" >&2 || true
    # the job's own exit code when it has one (143: stopped by TERM), else 1
    case "${last#EXIT }" in ''|*[!0-9]*) return 1 ;; *) return "${last#EXIT }" ;; esac
  fi
  echo "[$name] done. Log: $LAST_LOG"
}

# pull_results: download every path a job announced with a line "CLOUDMULE_RESULT <path relative to REMOTE_DIR>".
# Best effort: also after a failed or stopped job (its own log and partial results are what explain it); a path
# that cannot be downloaded is reported (RESULT_MISSING) and the others still come.
pull_results() {
  local p
  [ -n "${LAST_LOG:-}" ] && [ -f "$LAST_LOG" ] || return 0
  for p in $(grep -E '^CLOUDMULE_RESULT ' "$LAST_LOG" | cut -d' ' -f2- | tr -d '\r'); do
    mkdir -p "$LOCAL_DIR/$(dirname "$p")"
    # copy INTO the parent folder: a re-run overwrites a result folder instead of nesting it inside itself
    if scp -q -r "${SSH_OPTS[@]}" "root@$IP:$REMOTE_DIR/$p" "$LOCAL_DIR/$(dirname "$p")/"; then
      echo "RESULT: $LOCAL_DIR/$p"
    else
      echo "RESULT_MISSING: $p (announced by the job, but it could not be downloaded)" >&2
    fi
  done
}

# ---------------------------------------------------------------- sync
# sync_project [--with-generated]: uploads only what changed (size + mtime vs the server) and deletes on the
# server what was deleted locally. SYNC_SEEDS = heavy generated files: uploaded only if the server lacks them,
# never overwritten (the server regenerates them) unless --with-generated.
sync_project() {
  local start=$(date +%s)
  sync_tree "$LOCAL_DIR" "$REMOTE_DIR" "$SYNC_EXCLUDE" "$SYNC_SEEDS" "$LEASE" "${1:-}"
  SYNC_CHANGED="$(cat "$CM_DIR/logs/.sync-push-$LEASE.txt")"
  # .cloudmule/files/ (optional): helpers and reference data for the jobs, in $REMOTE_DIR/.cloudmule-files
  # ($CLOUDMULE_FILES); the rest of .cloudmule/ (settings, jobs) is never uploaded
  if [ -d "$PROJECT_DIR/files" ]; then
    echo "  .cloudmule/files/ -> .cloudmule-files/"
    sync_tree "$PROJECT_DIR/files" "$REMOTE_DIR/.cloudmule-files" "" "" "$LEASE-files" ""
  else
    rsh "rm -rf '$REMOTE_DIR/.cloudmule-files'"
  fi
  echo "SYNC_OK in $(( $(date +%s) - start )) s"
}

# sync_tree <local dir> <remote dir> <exclude> <seeds> <list tag> [--with-generated]: one folder's upload (sync_project)
sync_tree() {
  local src="$1" dst="$2" ex="$3" seeds="$4" plist="$CM_DIR/logs/.sync-push-$5.txt" dlist="$CM_DIR/logs/.sync-delete-$5.txt"
  local flag="${6:-}" prune
  prune="$(tools find-prune "$ex" "$seeds")"
  rsh "mkdir -p '$dst' && cd '$dst' && find . $prune -type f -printf '%P\t%s\t%T@\n'" \
    | tools sync-plan "$(winpath "$src")" "$(winpath "$plist")" "$(winpath "$dlist")" \
        --exclude "$ex" --seeds "$seeds" $flag
  if [ -s "$plist" ]; then tar cf - -C "$src" -T "$plist" | rsh "tar --no-same-owner -xf - -C '$dst'"; fi   # (a pod's container cannot chown)
  if [ -s "$dlist" ]; then rsh "cd '$dst' && xargs -d '\n' rm -f --" < "$dlist"; fi
}

# install_project: runs INSTALL_CMD on the server when a trigger file changed or INSTALL_CHECK fails
install_project() {
  [ -n "$INSTALL_CMD" ] || return 0
  local need=0 f
  for f in $INSTALL_TRIGGERS; do
    [[ $'\n'"$SYNC_CHANGED"$'\n' == *$'\n'"$f"$'\n'* ]] && need=1
  done
  if [ "$need" = 0 ] && [ -n "$INSTALL_CHECK" ] && ! rsh "cd '$REMOTE_DIR' && $JOB_ENV && $INSTALL_CHECK" >/dev/null 2>&1; then need=1; fi
  [ "$need" = 1 ] || return 0
  echo "== Installing dependencies on the server =="
  remote_job "$LEASE-install" "$REMOTE_DIR" "$JOB_ENV; $INSTALL_CMD; ${INSTALL_CHECK:-true}"
}

# ---------------------------------------------------------------- RunPod GPU pods (docs/specs/0004)
# Only for work that needs a GPU: one pod per job, never shared, deleted when the job ends. The API calls live in
# tools.py (rp-*); the caps from .env are enforced there, also when the user approves each pod by hand.
# rp_files: RP_FILES = the options every rp-* command takes: this computer's pod records and usage file
rp_files() {
  RP_FILES=(--records "$(winpath "$POD_RECORDS")" --usage "$(winpath "$USAGE_FILE")" --keep-days "$USAGE_KEEP_DAYS"
            --cache "$(winpath "$CM_DIR/logs/runpod-catalog.json")")   # the catalog cache: gpus writes it, gpu reads it
}
# rp_tools <rp-command> [args…]: tools.py with the pod records and usage file
rp_tools() { rp_files; tools "$@" "${RP_FILES[@]}"; }

# need_runpod: the RunPod key is in .env and the caps are numbers
need_runpod() {
  [ -n "${RUNPOD_API_KEY:-}" ] || die "RUNPOD_API_KEY is missing in $CM_DIR/.env. The user creates a RunPod API key
that can manage pods and has \"catalog read\" permission (runpod.io -> Settings -> API Keys) and pastes it there
themselves (see .env.example)."
  local v
  for v in RUNPOD_MAX_USD_PER_HOUR RUNPOD_MAX_MINUTES RUNPOD_MAX_USD_PER_DAY; do
    [[ "${!v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$v in $CM_DIR/.env must be a number (it is '${!v}')"
  done
  [ -z "$RUNPOD_MAX_USD_PER_MONTH" ] || [[ "$RUNPOD_MAX_USD_PER_MONTH" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || die "RUNPOD_MAX_USD_PER_MONTH in $CM_DIR/.env must be a number, or empty for no monthly cap"
  [ -z "$RUNPOD_MAX_USD_PER_MONTH" ] || [ "${USAGE_KEEP_DAYS%%.*}" -ge 31 ] 2>/dev/null \
    || die "RUNPOD_MAX_USD_PER_MONTH needs USAGE_KEEP_DAYS >= 31 in $CM_DIR/.env (the month's spend is read from usage.tsv)"
  [ -z "$RUNPOD_APT_MIRROR" ] || [[ "$RUNPOD_APT_MIRROR" =~ ^https?://[A-Za-z0-9._/-]+$ ]] \
    || die "RUNPOD_APT_MIRROR must be an http(s) URL of an Ubuntu mirror (letters, digits, . _ / -), or empty"
  [ -z "$RUNPOD_MAX_PODS" ] || [[ "$RUNPOD_MAX_PODS" =~ ^[1-9][0-9]*$ ]] \
    || die "RUNPOD_MAX_PODS in $CM_DIR/.env must be a whole number >= 1, or empty for no limit"
  case "$RUNPOD_STANDING_APPROVAL" in 0|1) ;; *) die "RUNPOD_STANDING_APPROVAL in $CM_DIR/.env must be 0 or 1" ;; esac
}

# gpu_budget: SPENT (today's GPU spend), RUNNING_WORST (the worst case of cloudmule pods running now), DAY_LEFT
# (what the daily cap still allows; DAY_LEFT_SHOWN rounded for people), all in USD. Deletes orphan pods on the way
# and says so. Fails closed: a number it cannot read stops the command instead of counting as 0.
gpu_budget() {
  local out num='^[0-9]+(\.[0-9]+)?$'
  out="$(rp_tools rp-pods --max-minutes "$RUNPOD_MAX_MINUTES" --reap --worst)" \
    || die "could not list the RunPod pods (reason above)"
  printf '%s\n' "$out" | grep '^ORPHAN_DELETED' || true
  RUNNING_WORST="$(printf '%s\n' "$out" | sed -n 's/^RUNNING_WORST_USD //p')"
  RUNNING_COUNT="$(printf '%s\n' "$out" | sed -n 's/^RUNNING_PODS //p')"; RUNNING_COUNT="${RUNNING_COUNT:-0}"
  RUNNING_LINES="$(printf '%s\n' "$out" | sed -n 's/^RUNNING_POD  /  /p')"
  SPENT="$(tools rp-spend "$(winpath "$USAGE_FILE")")" || die "could not read today's GPU spend from $USAGE_FILE"
  [[ "$RUNNING_WORST" =~ $num ]] && [[ "$SPENT" =~ $num ]] \
    || die "could not work out today's GPU spend (spent '$SPENT', running '$RUNNING_WORST'): no pod is created"
  read -r SPENT RUNNING_WORST DAY_LEFT DAY_LEFT_SHOWN <<< "$(awk -v c="$RUNPOD_MAX_USD_PER_DAY" -v s="$SPENT" \
    -v r="$RUNNING_WORST" 'BEGIN { printf "%.2f %.2f %.4f %.2f", s, r, c - s - r, c - s - r }')"
  # the calendar month (RUNPOD_MAX_USD_PER_MONTH, optional): MONTH_SPENT always, MONTH_LEFT "none" without a cap
  MONTH_SPENT="$(tools rp-spend "$(winpath "$USAGE_FILE")" --month)" && [[ "$MONTH_SPENT" =~ $num ]] \
    || die "could not work out this month's GPU spend from $USAGE_FILE: no pod is created"
  MONTH_LEFT=none; MONTH_NEAR=0
  if [ -n "$RUNPOD_MAX_USD_PER_MONTH" ]; then
    read -r MONTH_SPENT MONTH_LEFT MONTH_NEAR <<< "$(awk -v c="$RUNPOD_MAX_USD_PER_MONTH" -v s="$MONTH_SPENT" \
      -v r="$RUNNING_WORST" 'BEGIN { printf "%.2f %.4f %d", s, c - s - r, (s >= 0.8 * c) }')"
  else
    MONTH_SPENT="$(awk -v s="$MONTH_SPENT" 'BEGIN { printf "%.2f", s }')"
  fi
}

# month_near: MONTHLY_CAP_NEAR when this month's spend reached 80 % of RUNPOD_MAX_USD_PER_MONTH
month_near() {
  [ "$MONTH_NEAR" = 0 ] || echo "MONTHLY_CAP_NEAR: $MONTH_SPENT of $RUNPOD_MAX_USD_PER_MONTH USD spent on GPU pods this month (tell the user)"
}

# month_line: this month's GPU spend and the monthly cap, for people
month_line() {
  if [ -n "$RUNPOD_MAX_USD_PER_MONTH" ]; then
    echo "This month's GPU spend: $MONTH_SPENT of $RUNPOD_MAX_USD_PER_MONTH USD (RUNPOD_MAX_USD_PER_MONTH)."
  else
    echo "This month's GPU spend: $MONTH_SPENT USD (no monthly cap: RUNPOD_MAX_USD_PER_MONTH is not set)."
  fi
}

# launch_lock: this computer's GPU launches one at a time, from the budget check until the pod exists, so parallel
# launches each count the worst case of the pods created before them (across computers the race is accepted).
# A lock whose process is gone is removed; waiting is bounded (CM_LAUNCH_LOCK_SECONDS, 120): LAUNCH_LOCK_TIMEOUT.
LAUNCH_LOCK="$CM_DIR/logs/runpod-launch.lock"; LAUNCH_LOCKED=0
launch_lock() {
  local waited=0 limit="${CM_LAUNCH_LOCK_SECONDS:-120}" holder
  until mkdir "$LAUNCH_LOCK" 2>/dev/null; do
    holder="$(cat "$LAUNCH_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # only if it still names that process (another launch may have just taken it over)
      [ "$(cat "$LAUNCH_LOCK/pid" 2>/dev/null || true)" != "$holder" ] \
        || { echo "(removed a stale launch lock: its process $holder is gone)"; rm -rf "$LAUNCH_LOCK"; }
      continue
    fi
    # a lock with no pid after 10 s: its process died between creating it and writing its pid
    if [ -z "$holder" ] && [ "$waited" -ge 10 ]; then
      echo "(removed a stale launch lock that names no process)"; rm -rf "$LAUNCH_LOCK"; continue
    fi
    [ "$waited" -lt "$limit" ] || die "LAUNCH_LOCK_TIMEOUT: another GPU launch on this computer (process ${holder:-?}) has held $LAUNCH_LOCK for $limit s; try again in a minute"
    [ "$waited" != 0 ] || echo "(another GPU launch on this computer is checking the budget: waiting for it)"
    sleep 1; waited=$((waited + 1))
  done
  echo "$$" > "$LAUNCH_LOCK/pid"; LAUNCH_LOCKED=1
}
launch_unlock() { [ "$LAUNCH_LOCKED" = 1 ] || return 0; rm -rf "$LAUNCH_LOCK"; LAUNCH_LOCKED=0; }

# last_gpu [--fields]: the user's last GPU choice, "<gpu> <cloud> (by <project>, <date>)" or "none yet";
# --fields: "<gpu><TAB><cloud>" (empty if none)
last_gpu() {
  local g c p d
  if [ ! -s "$LAST_GPU_FILE" ]; then [ "${1:-}" = --fields ] || echo "none yet"; return 0; fi
  IFS=$'\t' read -r g c p d < "$LAST_GPU_FILE" || true
  if [ "${1:-}" = --fields ]; then printf '%s\t%s\n' "$g" "$c"; else echo "$g $c (by $p, $d)"; fi
}

# cloud_name <secure|community|all>: the RunPod cloud(s) as the API names them
cloud_name() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    secure) echo SECURE ;; community) echo COMMUNITY ;; all) echo "SECURE COMMUNITY" ;;
    *) die "--cloud must be secure, community or all (not '${1:-}')" ;;
  esac
}

# gpu_refusals <job>: every reason not to create a pod, checked before anything is created (each one line, with
# its code first, exit non-zero). The caps are checked by rp-launch, also before creating.
gpu_refusals() {
  job_script "$1" >/dev/null
  [ -z "$GPU_SELFTEST" ] || [ -f "$PROJECT_DIR/jobs/$GPU_SELFTEST.sh" ] || die "GPU_SELFTEST_MISSING: $PROJECT_DIR/config.sh says GPU_SELFTEST=$GPU_SELFTEST, but there is no jobs/$GPU_SELFTEST.sh"
  [ "$NEEDS_GPU" != 0 ] || die "NO_GPU_NEEDED: $PROJECT_DIR/config.sh says NEEDS_GPU=0 (CPU work runs on the Hetzner server); set NEEDS_GPU=graphics or cuda there if this work needs a GPU"
  # unset: the pod would not know whether to prepare Chrome + Vulkan, and a silent software fallback burns the cap
  [ -n "$NEEDS_GPU" ] || die "NEEDS_GPU_UNSET: $PROJECT_DIR/config.sh does not say what GPU work this is: ask the user, then write NEEDS_GPU=graphics (WebGL/Vulkan in Chrome) or NEEDS_GPU=cuda there"
  [ -n "$GPU_CHOICE" ] || die "NEEDS_GPU_CHOICE: show the options (cloudmule gpus $PROJECT${TARGET:+ $TARGET}), wait for the user's choice, then add --gpu <id>[,<id>…] (last choice: $(last_gpu))"
  [ "$GPU_CLOUD" = SECURE ] || die "NO_FITTING_GPU: COMMUNITY pods have no public SSH; only --cloud secure can be used"
  case " $(module_archs base $(gpu_modules)) " in *" x86 "*) ;;
    *) die "NO_FITTING_GPU: GPU pods are x86, but a module in MODULES is not ($MODULES)" ;; esac
  [ "$DRY_RUN" = 1 ] || [ "$RUNPOD_STANDING_APPROVAL" = 1 ] || [ "$APPROVED" = 1 ] || die "NEEDS_APPROVAL: show the user the GPU, its price and worst case (cloudmule gpus $PROJECT${TARGET:+ $TARGET}), wait for their yes, then add --approved (or the user sets RUNPOD_STANDING_APPROVAL=1 in cloudmule's .env)"
}

# gpu_modules: the modules a pod installs, in order: for graphics work chrome-libs and gpu-graphics come first;
# each module once
gpu_modules() {
  local m out=""
  [ "$NEEDS_GPU" != graphics ] || out="chrome-libs gpu-graphics"
  for m in $MODULES; do case " $out " in *" $m "*) ;; *) out="$out $m" ;; esac; done
  printf '%s' "${out# }"
}

# pod_image: the pod's image: the project's RUNPOD_IMAGE, else the default for its kind of GPU work
pod_image() {
  if [ -n "${RUNPOD_IMAGE:-}" ]; then echo "$RUNPOD_IMAGE"
  elif [ "$NEEDS_GPU" = graphics ]; then echo "$RUNPOD_IMAGE_GRAPHICS_DEFAULT"
  else echo "$RUNPOD_IMAGE_DEFAULT"; fi
}

# phase <name>: adds "<name>=<seconds since the previous phase>" to PHASES (a GPU run's phase timings)
PHASES=""; PHASE_T=""; PULL_SECONDS=0
phase() { local now; now=$(date +%s); PHASES="$PHASES $1=$(( now - ${PHASE_T:-$now} ))"; PHASE_T=$now; }

# pod_name <job>: cloudmule-<project>[-<target>]-<job>-<run tag> (cloudmule's pods are recognised by the prefix;
# the run's random tag keeps two sessions running the same job from ever touching each other's pod)
pod_name() {
  local base
  base="$(printf 'cloudmule-%s%s-%s' "$PROJECT" "${TARGET:+-$TARGET}" "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-90)"
  printf '%s-%s' "$base" "${RUN##*-}"
}

# forget_stale_pod_keys: deletes throwaway pod keys left by a run that never reached its EXIT trap (killed, or the
# computer went off): older than the time cap + 5 min, with no pod record of that run left. Younger keys may belong
# to another session's pod that is still starting.
forget_stale_pod_keys() {
  local k run
  # private keys only (pod-<run>, no dot); a run with a record left keeps everything, its .measure included.
  # +5: the same grace as RP_REAP_GRACE_MIN in tools.py
  find "$CM_DIR/keys" -name 'pod-*' ! -name '*.*' -mmin +"$(awk -v m="$RUNPOD_MAX_MINUTES" 'BEGIN { printf "%d", m + 5 }')" \
    2>/dev/null | while IFS= read -r k; do
    run="${k##*/pod-}"
    grep -l "\"run\": \"$run\"" "$POD_RECORDS"/*.json >/dev/null 2>&1 \
      || rm -f "$k" "$k.pub" "$k.known_hosts" "$k.measure" "$k.addr" || true
  done
}

# seconds_of <minutes>: whole seconds (the caps may have decimals)
seconds_of() { awk -v m="$1" 'BEGIN { printf "%d", m * 60 }'; }

# pod_watchdog: layer 2 of 3 (with the EXIT trap and the pod guard). A detached local process that deletes this
# run's pods after RUNPOD_MAX_MINUTES, even if this command is killed. Started before the pod is created.
pod_watchdog() {
  rp_files
  nohup "$PY" -I "$CM_DIR/bin/tools.py" rp-reap --run "$RUN" --after "$(seconds_of "$POD_MAX_MINUTES")" \
    --measure "$(winpath "$POD_KEY.measure")" "${RP_FILES[@]}" >/dev/null 2>&1 < /dev/null &
  WATCHDOG=$!
}

# pod_finish: layer 1, the EXIT trap of `gpu`: deletes this run's pod (and records its usage line with the cost),
# then the throwaway key. Keeps the command's exit code.
pod_finish() {
  local rc=$? t0
  trap - EXIT INT TERM HUP
  launch_unlock
  # the phases so far go into the pod's usage line (rp-delete adds how long the delete took)
  [ -z "$PHASES" ] || printf 'PHASES%s\n' "$PHASES" >> "$POD_KEY.measure"
  rm -f "$POD_KEY" "$POD_KEY.pub" "$POD_KEY.known_hosts" "$POD_KEY.addr"
  t0=$(date +%s)
  if rp_tools rp-delete --run "$RUN" --measure "$(winpath "$POD_KEY.measure")"; then
    [ -z "${WATCHDOG:-}" ] || kill "$WATCHDOG" 2>/dev/null || true   # its work is done
    rm -f "$POD_KEY.measure"
    [ -z "$PHASES" ] || [ -z "${POD_ID:-}" ] || pod_note "PHASES${PHASES} delete=$(( $(date +%s) - t0 ))"
    pod_log_merge
  else   # the watchdog still has the measurement for the pod's usage line
    echo "WARNING: the GPU pod of this run could not be deleted now. The watchdog retries after $POD_MAX_MINUTES" \
         "min and the pod deletes itself; check with 'cloudmule status'." >&2
    [ -z "$PHASES" ] || [ -z "${POD_ID:-}" ] || pod_note "PHASES${PHASES}"
    pod_log_merge
  fi
  exit "$rc"
}

# pod_ssh <ip> <port>: IP and SSH_OPTS for this run's pod: its throwaway key and its own known_hosts
pod_ssh() {
  IP="$1"
  SSH_OPTS=(-i "$POD_KEY" -o IdentitiesOnly=yes -o Port="$2" -o UserKnownHostsFile="$POD_KEY.known_hosts"
            -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6
            -o ConnectTimeout=10 -o LogLevel=ERROR)
}

# pod_guard: layer 3, the guard INSIDE the pod (remote/pod-guard.sh): deletes the pod when its time is up, with
# the pod's own credentials, even if this computer is off. Started first thing after SSH answers.
# pod_seconds_left: seconds until this run's pod reaches its time cap (at least 1)
pod_seconds_left() {
  local left=$(( $(seconds_of "$POD_MAX_MINUTES") - ( $(date +%s) - POD_T0 ) ))
  [ "$left" -gt 0 ] || left=1
  echo "$left"
}

pod_guard() {
  local left; left="$(pod_seconds_left)"
  rsh "mkdir -p $R && cat > $R/pod-guard.sh && { nohup setsid bash $R/pod-guard.sh $left > $R/pod-guard.log 2>&1 < /dev/null & }" \
    < "$CM_DIR/remote/pod-guard.sh"
  echo "Pod guard armed: the pod deletes itself in $(( left / 60 )) min even if this computer is off."
}

# ---------------------------------------------------------------- GPU pods: checks, watcher, deadline (spec 0005)
# pod_note <line…>: prints a line and keeps it for the job's local log (pod_log_merge)
pod_note() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$POD_NOTES"; }

# pod_allotment: the pod's own CPUs and RAM (its cgroup, through remote/gpu-watch.sh; else RunPod's catalog for its
# GPU, said so), printed as POD_CPUS/POD_RAM_GB and given to jobs as CLOUDMULE_CPUS/CLOUDMULE_RAM_GB: `nproc` and
# /proc/meminfo inside a RunPod container show the whole host. Uploads the watcher for later.
pod_allotment() {
  local line c r note=""
  rsh "mkdir -p $R && cat > $R/gpu-watch.sh" < "$CM_DIR/remote/gpu-watch.sh"
  line="$(rsh "bash $R/gpu-watch.sh alloc" 2>/dev/null | grep '^POD_CPUS=' | tail -1)" || line=""
  c="$(printf '%s' "$line" | sed -n 's/^POD_CPUS=\([0-9]*\).*/\1/p')"
  r="$(printf '%s' "$line" | sed -n 's/.*POD_RAM_GB=\([0-9]*\).*/\1/p')"
  if [ -z "$c" ] && [ -n "${POD_CAT_CPUS:-}" ]; then c="$POD_CAT_CPUS"; note="$note; CPUs from RunPod's catalog (no CPU quota in the pod's cgroup)"; fi
  if [ -z "$r" ] && [ -n "${POD_CAT_RAM:-}" ]; then r="$POD_CAT_RAM"; note="$note; RAM from RunPod's catalog (no memory limit in the pod's cgroup)"; fi
  POD_CPUS="$c"; POD_RAM_GB="$r"
  pod_note "POD_CPUS=${POD_CPUS:-unknown} POD_RAM_GB=${POD_RAM_GB:-unknown}${note:+ (${note#; })} (jobs: CLOUDMULE_CPUS, CLOUDMULE_RAM_GB; never nproc)"
  [ -z "$POD_CPUS" ] || JOB_ENV="$JOB_ENV CLOUDMULE_CPUS=$POD_CPUS"
  [ -z "$POD_RAM_GB" ] || JOB_ENV="$JOB_ENV CLOUDMULE_RAM_GB=$POD_RAM_GB"
}

# gpu_graphics_env: the project's Chrome backend (GPU_GRAPHICS_BACKEND, GL/EGL by default) becomes the pod's
# /etc/cloudmule/chrome-gpu-flags; jobs get the flags, the ANGLE backend and where to tee Chrome's stderr
gpu_graphics_env() {
  # the host's NVIDIA graphics libraries (a no-op when the container has them; needed with a prebuilt image)
  rsh "cloudmule-gpu-libs; cp -f /etc/cloudmule/chrome-gpu-flags.$GPU_GRAPHICS_BACKEND /etc/cloudmule/chrome-gpu-flags"
  [ "$GPU_GRAPHICS_BACKEND" = gl-egl ] \
    || echo "NOTE: GPU_GRAPHICS_BACKEND=$GPU_GRAPHICS_BACKEND (not the default gl-egl): only if your page survives the context-loss check"
  JOB_ENV="$JOB_ENV CLOUDMULE_CHROME_ANGLE=$GPU_GRAPHICS_BACKEND CLOUDMULE_CHROME_LOG=$R/chrome-gpu.log"
  JOB_ENV="$JOB_ENV CLOUDMULE_CHROME_GPU_FLAGS=\"\$(cat /etc/cloudmule/chrome-gpu-flags)\""
}

# webgl_check [--quick]: cloudmule-webgl-check on the pod. Its whole output is shown, appended to the pod's
# $R/webgl-check.log and kept for the job's local log. Returns its exit code (3 GPU_NOT_USED, 4 GPU_CONTEXT_LOST).
webgl_check() {
  local rc=0 out
  out="$(rsh "cloudmule-webgl-check $* 2>&1 | tee -a $R/webgl-check.log; exit \${PIPESTATUS[0]}")" || rc=$?
  printf '%s\n' "$out"
  { echo "== cloudmule-webgl-check $* (exit $rc)"; printf '%s\n' "$out"; } >> "$POD_NOTES"
  return "$rc"
}

# webgl_refusal <exit code>: the result code of a failed check before the upload (the pod is deleted by the trap)
webgl_refusal() {
  [ "$1" != 255 ] || die "NO_PUBLIC_SSH: the GPU pod stopped answering over SSH during the WebGL check: nothing was uploaded"
  if [ "$1" = 4 ]; then
    die "GPU_CONTEXT_LOST: Chrome lost its WebGL context (or drew a canvas texture wrong) on this pod's GPU with the $GPU_GRAPHICS_BACKEND backend: nothing was uploaded"
  fi
  die "GPU_NOT_USED: Chrome does not render WebGL on this pod's NVIDIA GPU (software rendering or no GPU): nothing was uploaded"
}

# pod_deadline: CLOUDMULE_DEADLINE (epoch seconds) = the pod's time cap minus a margin (5 min; an eighth of a cap
# under 40 min). There `gpu` stops the job (TERM), downloads what it announced and deletes the pod.
pod_deadline() {
  local cap_s margin
  cap_s="$(seconds_of "$POD_MAX_MINUTES")"
  margin=$(( cap_s / 8 < 300 ? cap_s / 8 : 300 ))
  POD_DEADLINE=$(( POD_T0 + cap_s - margin ))
  WAIT_DEADLINE="$POD_DEADLINE"; STOP_GRACE=$(( margin / 2 < 60 ? margin / 2 : 60 )); [ "$STOP_GRACE" -ge 1 ] || STOP_GRACE=1
  JOB_ENV="$JOB_ENV CLOUDMULE_DEADLINE=$POD_DEADLINE"
}

# gpu_watch_start <job>: the watcher (remote/gpu-watch.sh) samples GPU, VRAM, CPU and RAM every 2 s until the job's
# log ends; for graphics it also scans Chrome's log (CLOUDMULE_CHROME_LOG). It never touches the job.
gpu_watch_start() {
  local chrome=- left
  [ "$NEEDS_GPU" != graphics ] || chrome="$R/chrome-gpu.log"
  left="$(pod_seconds_left)"
  # a fresh Chrome log: what the self-test logged there is not this job's
  rsh "rm -f $R/gpu-watch.log; [ \"$chrome\" = - ] || : > $chrome; { nohup setsid bash $R/gpu-watch.sh run $R/gpu-watch.log $R/jobs/$LEASE-$1.log $chrome '${POD_CPUS:-}' $left > /dev/null 2>&1 < /dev/null & }"
}

# gpu_watch_summary: the watcher's log, downloaded next to the job's log; prints GPU_USE (copied to the usage line),
# the slots hint and, for graphics, GPU_DEGRADED lines (GPU_DEGRADED_WHY = the first reason)
gpu_watch_summary() {
  local f="$CM_DIR/logs/.gpu-watch-$RUN.log" out
  rsh "cat $R/gpu-watch.log" > "$f" 2>/dev/null || true
  out="$(tools gpu-summary "$(winpath "$f")" --needs "$NEEDS_GPU" --cpus "${POD_CPUS:-}" --ram-gb "${POD_RAM_GB:-}")" \
    || out="GPU_USE n/a (could not read the watcher's log)"
  pod_note "$out"
  printf '%s\n' "$out" | grep '^GPU_USE ' >> "$POD_KEY.measure" || true
  GPU_DEGRADED_WHY="$(printf '%s\n' "$out" | sed -n 's/^GPU_DEGRADED: //p' | head -1)"
  if [ -n "${LAST_LOG:-}" ] && [ -s "$f" ]; then mv -f "$f" "${LAST_LOG%.log}.gpu-watch.log"; else rm -f "$f"; fi
}

# pod_log_merge: what the run printed about the pod (checks, allotment, GPU use, phases) goes at the end of the
# job's local log (logs/<project>-<job>-*.log); one is created when the run stopped before its job
pod_log_merge() {
  [ -s "${POD_NOTES:-}" ] || { rm -f "${POD_NOTES:-}"; return 0; }
  local log="${MAIN_LOG:-}"
  [ -n "$log" ] && [ -f "$log" ] || log="$CM_DIR/logs/$LEASE-$GPU_JOB-$(date +%Y%m%d-%H%M).log"
  { echo "== cloudmule gpu: the pod (run $RUN)"; cat "$POD_NOTES"; } >> "$log" 2>/dev/null || true
  rm -f "$POD_NOTES"
}
