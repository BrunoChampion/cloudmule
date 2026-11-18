# cloudmule core library. Sourced by bin/cloudmule; don't run it directly.
# Never print $HCLOUD_TOKEN and never use `set -x` here.
set -euo pipefail

CM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# settings given in the environment win over .env (e.g. IDLE_MINUTES=10 cloudmule start …)
CM_SETTINGS='LOCATIONS|IDLE_MINUTES|SESSION_MAX_HOURS|ONESHOT_IDLE_MINUTES|ONESHOT_MAX_HOURS|BASE_IMAGE|SERVER_NAME|LOG_KEEP_DAYS|USAGE_KEEP_DAYS'
CM_FROM_ENV="$(env | grep -E "^($CM_SETTINGS)=" || true)"
# RunPod's caps and the standing approval count only from .env: nobody raises them for one command
unset RUNPOD_MAX_USD_PER_HOUR RUNPOD_MAX_MINUTES RUNPOD_MAX_USD_PER_DAY RUNPOD_STANDING_APPROVAL
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
RUNPOD_STANDING_APPROVAL=${RUNPOD_STANDING_APPROVAL:-0}    # 1 = GPU pods may be created without asking each time
RUNPOD_BOOT_SECONDS=${RUNPOD_BOOT_SECONDS:-300}            # no public SSH after this long: NO_PUBLIC_SSH, deleted
RUNPOD_POLL_SECONDS=${RUNPOD_POLL_SECONDS:-10}
RUNPOD_IMAGE_DEFAULT="runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04"   # SSH preconfigured, CUDA 11.8
POD_RECORDS="$CM_DIR/logs/runpod"                        # one record per GPU pod this computer created, until it is deleted
LAST_GPU_FILE="$CM_DIR/logs/last-gpu"             # the user's last GPU choice: gpu, cloud, project, date (tabs)
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
    [ -f "$CM_DIR/remote/modules/${spec%%@*}.sh" ] \
      || die "unknown module '${spec%%@*}' in MODULES. Available: $(ls "$CM_DIR/remote/modules" | sed 's/\.sh$//' | tr '\n' ' ')"
  done
  SYNC_EXCLUDE="$SYNC_EXCLUDE .cloudmule .cloudmule-out"   # settings and results never need uploading
  # what the server must offer this project (defaults are safe for small projects)
  RAM_SRC=config; [ -n "$MIN_RAM_GB" ] || { MIN_RAM_GB=4; RAM_SRC=default; }
  CPUS_SRC=config; [ -n "$MIN_CPUS" ] || { MIN_CPUS=2; CPUS_SRC=default; }
  DISK_SRC=config; [ -n "$MIN_DISK_GB" ] || { MIN_DISK_GB=40; DISK_SRC=default; }
  case "$NEEDS_GPU" in ""|0|graphics|cuda) ;; *) die "NEEDS_GPU in $PROJECT_DIR/config.sh must be 0, graphics or cuda" ;; esac
  VRAM_SRC=config; [ -n "$MIN_VRAM_GB" ] || { MIN_VRAM_GB=8; VRAM_SRC=default; }
  PROJECT_ARCHS="$(module_archs base $MODULES)"
  LEASE="$PROJECT${TARGET:+--$TARGET}"   # this project's claim on the shared server
  # versioned modules (node@24.15.0) live in /opt/<module>/<version>: put this project's versions first on PATH
  JOB_ENV="export PATH=$(for spec in $MODULES; do [[ "$spec" != *@* ]] || printf '/opt/%s/%s/bin:' "${spec%%@*}" "${spec#*@}"; done)\$PATH"
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

wait_ssh() {
  local _
  for _ in $(seq 1 60); do
    if rsh true 2>/dev/null; then return 0; fi
    sleep 3
  done
  echo "ERROR: the server did not answer over SSH within 3 min" >&2
  return 1
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
# ensure_modules: install on the running server every module of this project it does not have yet (markers
# $R/mod/<module>[@version]). They persist in the shared workspace snapshot, so each one installs once.
ensure_modules() {
  local spec m v missing
  missing="$(rsh "for s in base $MODULES; do test -f $R/mod/\$s || printf ' %s' \"\$s\"; done")"
  [ -n "$missing" ] || return 0
  echo "== Installing on the server:$missing =="
  tar cf - -C "$CM_DIR/remote" modules | rsh "mkdir -p $R && rm -rf $R/modules && tar xf - -C $R"
  for spec in $missing; do
    m="${spec%%@*}"; v=""; [ "$spec" = "$m" ] || v="${spec#*@}"
    remote_job "module-$m" /root "set -euo pipefail; export DEBIAN_FRONTEND=noninteractive VERSION=$(printf '%q' "$v"); \
      . $R/modules/$m.sh && mkdir -p $R/mod && touch $R/mod/$spec"
  done
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
  inner="touch $log.run; s=\$(date +%s); ( $cmd ) > $log 2>&1; rc=\$?; { $MEASURE; } > $use 2>/dev/null
         echo \"EXIT \$rc\" >> $log"
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

# job_label <remote job name>: the job's name without its lease or project prefix (for its usage line)
job_label() {
  local n="$1"
  if [ -n "${LEASE:-}" ] && [ "${n#"$LEASE-"}" != "$n" ]; then echo "${n#"$LEASE-"}"
  elif [ -n "${PROJECT:-}" ]; then echo "${n#"$PROJECT-"}"
  else echo "$n"; fi
}

# remote_wait <name>: follow (or re-attach to) a remote job until it ends; progress every 20 s
remote_wait() {
  local name="$1" log="$R/jobs/$1.log" start last
  rsh "test -f $log" || { echo "ERROR: there is no job '$name' on the server" >&2; return 1; }
  start=$(date +%s); last=""
  while true; do
    last="$(rsh "tail -c 4000 $log 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -1" 2>/dev/null || echo '(no connection, retrying)')"
    case "$last" in "EXIT "*) break ;; esac
    echo "[$name $(( ($(date +%s) - start) / 60 )) min] $last"
    sleep 20
  done
  LAST_LOG="$CM_DIR/logs/$name-$(date +%Y%m%d-%H%M).log"
  rsh "[ ! -d /run/cloudmule ] || date +%s > /run/cloudmule/last_active" 2>/dev/null || true   # a job just ended: in use
  rsh "cat $log" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' > "$LAST_LOG" || true
  # the job's measurements (this run, and an uncollected previous one) into logs/usage.tsv, each exactly once:
  # `mv` is atomic, so of a `job` and an `attach` collecting at the same moment only one gets the file
  rsh "for f in $R/jobs/$name.usage.prev $R/jobs/$name.usage; do
         mv \"\$f\" \"\$f.\$\$\" 2>/dev/null && cat \"\$f.\$\$\" && rm -f \"\$f.\$\$\"; done; true" 2>/dev/null \
    | tools usage-add "$(winpath "$USAGE_FILE")" "$USAGE_KEEP_DAYS" "${PROJECT:--}" "${TARGET:-}" "$(job_label "$name")" \
    || true
  tools prune-logs "$(winpath "$CM_DIR/logs")" "$LOG_KEEP_DAYS" || true
  if [ "$last" != "EXIT 0" ]; then
    echo "ERROR: '$name' failed ($last). Log: $LAST_LOG" >&2
    tail -20 "$LAST_LOG" >&2 || true
    return 1
  fi
  echo "[$name] done. Log: $LAST_LOG"
}

# pull_results: download every path a job announced with a line "CLOUDMULE_RESULT <path relative to REMOTE_DIR>"
pull_results() {
  local p
  for p in $(grep -E '^CLOUDMULE_RESULT ' "$LAST_LOG" | cut -d' ' -f2- | tr -d '\r'); do
    mkdir -p "$LOCAL_DIR/$(dirname "$p")"
    # copy INTO the parent folder: a re-run overwrites a result folder instead of nesting it inside itself
    scp -q -r "${SSH_OPTS[@]}" "root@$IP:$REMOTE_DIR/$p" "$LOCAL_DIR/$(dirname "$p")/"
    echo "RESULT: $LOCAL_DIR/$p"
  done
}

# ---------------------------------------------------------------- sync
# sync_project [--with-generated]: uploads only what changed (size + mtime vs the server) and deletes on the
# server what was deleted locally. SYNC_SEEDS = heavy generated files: uploaded only if the server lacks them,
# never overwritten (the server regenerates them) unless --with-generated.
sync_project() {
  local flag="${1:-}" plist="$CM_DIR/logs/.sync-push-$LEASE.txt" dlist="$CM_DIR/logs/.sync-delete-$LEASE.txt" start prune
  prune="$(tools find-prune "$SYNC_EXCLUDE" "$SYNC_SEEDS")"
  rsh "mkdir -p '$REMOTE_DIR' && cd '$REMOTE_DIR' && find . $prune -type f -printf '%P\t%s\t%T@\n'" \
    | tools sync-plan "$(winpath "$LOCAL_DIR")" "$(winpath "$plist")" "$(winpath "$dlist")" \
        --exclude "$SYNC_EXCLUDE" --seeds "$SYNC_SEEDS" $flag
  start=$(date +%s)
  if [ -s "$plist" ]; then tar cf - -C "$LOCAL_DIR" -T "$plist" | rsh "tar xf - -C '$REMOTE_DIR'"; fi
  if [ -s "$dlist" ]; then rsh "cd '$REMOTE_DIR' && xargs -d '\n' rm -f --" < "$dlist"; fi
  SYNC_CHANGED="$(cat "$plist")"
  echo "SYNC_OK in $(( $(date +%s) - start )) s"
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
# rp_tools <rp-command> [args…]: tools.py with this computer's pod records and usage file
rp_tools() {
  tools "$@" --records "$(winpath "$POD_RECORDS")" --usage "$(winpath "$USAGE_FILE")" --keep-days "$USAGE_KEEP_DAYS"
}

# need_runpod: the RunPod key is in .env and the caps are numbers
need_runpod() {
  [ -n "${RUNPOD_API_KEY:-}" ] || die "RUNPOD_API_KEY is missing in $CM_DIR/.env. The user creates a RunPod API key
that can manage pods and has \"catalog read\" permission (runpod.io -> Settings -> API Keys) and pastes it there
themselves (see .env.example)."
  local v
  for v in RUNPOD_MAX_USD_PER_HOUR RUNPOD_MAX_MINUTES RUNPOD_MAX_USD_PER_DAY; do
    [[ "${!v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$v in $CM_DIR/.env must be a number (it is '${!v}')"
  done
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
  SPENT="$(tools rp-spend "$(winpath "$USAGE_FILE")")" || die "could not read today's GPU spend from $USAGE_FILE"
  [[ "$RUNNING_WORST" =~ $num ]] && [[ "$SPENT" =~ $num ]] \
    || die "could not work out today's GPU spend (spent '$SPENT', running '$RUNNING_WORST'): no pod is created"
  read -r SPENT RUNNING_WORST DAY_LEFT DAY_LEFT_SHOWN <<< "$(awk -v c="$RUNPOD_MAX_USD_PER_DAY" -v s="$SPENT" \
    -v r="$RUNNING_WORST" 'BEGIN { printf "%.2f %.2f %.4f %.2f", s, r, c - s - r, c - s - r }')"
}

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
