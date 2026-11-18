#!/usr/bin/env bash
# cloudmule's test suite. Drives the `cloudmule` command exactly like a user, as a brand-new user would have it:
# a copy of exactly the files a clone gets, an empty HOME, a separate Claude Code config and a FAKE `hcloud`
# (tests/fake-hcloud) first on PATH. No token, no network to Hetzner, no money, nothing outside a temp folder.
#
#   bash tests/run.sh            run everything; exit 1 if anything fails
#
# Assertions only use what a user can see: exit codes, printed lines, files on disk and the fake hcloud's call log.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cloudmule-test.XXXXXX")" && pwd)"   # canonical path (macOS TMPDIR ends in /)
trap 'rm -rf "$WORK"' EXIT
PASSES=0; FAILS=0; SKIPS=0
pass() { PASSES=$((PASSES + 1)); echo "PASS  $*"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $*"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/      | /' | head -15; }
skip() { SKIPS=$((SKIPS + 1)); echo "SKIP  $*"; }
# check <description> <command…>: passes when the command succeeds
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
has() { printf '%s\n' "$OUT" | grep -F -- "$1" >/dev/null; }
hasnt() { ! has "$1"; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# ---------------------------------------------------------------- a brand-new user's computer
CM_HOME="$WORK/cloudmule"
mkdir -p "$CM_HOME" "$WORK/home" "$WORK/claude-config"
(cd "$REPO" && git ls-files -co --exclude-standard | tar cf - -T -) | tar xf - -C "$CM_HOME"
export HOME="$WORK/home" CLAUDE_CONFIG_DIR="$(winpath "$WORK/claude-config")"
export PATH="$REPO/tests/fake-hcloud:$PATH" FAKE_HC_LOG="$WORK/hcloud.log"
chmod +x "$REPO/tests/fake-hcloud/hcloud" 2>/dev/null || true
: > "$FAKE_HC_LOG"
cm() { bash "$CM_HOME/bin/cloudmule" "$@" 2>&1; }
ALL_OUT="$WORK/all-output.log"   # every output of `run`, to prove no secret is ever printed
run() { OUT="$(cm "$@")"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"; }   # sets OUT and RC
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then PY=python3; else PY=python; fi

# A fake RunPod API on 127.0.0.1 (tests/fake-runpod): no key, no network, no money. Each test sets its scenario.
RP="$WORK/fake-runpod"; mkdir -p "$RP"
"$PY" -I "$(winpath "$REPO/tests/fake-runpod/server.py")" "$(winpath "$RP")" >/dev/null 2>&1 &
RP_PID=$!
trap 'kill "$RP_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 100); do [ -s "$RP/port" ] && break; sleep 0.1; done
export RUNPOD_API_BASE="http://127.0.0.1:$(cat "$RP/port")/v2"
RP_KEY="fake-runpod-key-for-tests"
scenario() { local s="${1:-}"; [ -n "$s" ] || s='{}'; printf '%s\n' "$s" > "$RP/scenario.json"; rm -f "$RP/state.json"; }
rp_log() { cat "$RP/requests.log" 2>/dev/null; }

echo "== a clone"
check "a clone has no .env, keys/, logs/ or registry/" \
  bash -c "[ ! -e '$CM_HOME/.env' ] && [ ! -e '$CM_HOME/keys' ] && [ ! -e '$CM_HOME/logs' ] && [ ! -e '$CM_HOME/registry' ]"
run help;     check "help works without a token" has "cloudmule servers"
run status;   check "a Hetzner command without a token asks for it" has "HCLOUD_TOKEN is missing"
run projects; check "no projects at first" has "no projects yet"
run usage;    check "usage works without a token, and says nothing is recorded yet" has "No job usage recorded yet"

printf 'HCLOUD_TOKEN=fake-token-for-tests\nLOCATIONS="nbg1 fsn1 hel1"\n' > "$CM_HOME/.env"

echo "== setup"
run setup
check "setup succeeds" has "SETUP_OK"
check "setup checks the token and points to the server menu" has "cloudmule servers"
check "setup registers this computer's key in Hetzner" grep -q '^ssh-key create ' "$FAKE_HC_LOG"
check "setup writes the location file" bash -c "[ \"\$(cat '$HOME/.config/cloudmule/home')\" = '$CM_HOME' ]"
if command -v claude >/dev/null 2>&1; then
  check "setup installs the Claude Code plugin (isolated config)" has "plugin 'cloudmule'"
  check "the plugin copy holds no secrets or keys" \
    bash -c "[ -z \"\$(find '$WORK/claude-config' \\( -name '.env' -o -name 'id_ed25519' \\) 2>/dev/null)\" ]"
else
  check "without Claude Code, setup prints how to install the plugin" has "/plugin marketplace add"
fi
fp="$(ssh-keygen -l -E md5 -f "$CM_HOME/keys/id_ed25519.pub" | awk '{print $2}' | sed 's/^MD5://')"
OUT="$(FAKE_HC_KEY_FP="$fp" cm setup)"; check "setup again: the registered key matches" has "already registered"
OUT="$(FAKE_HC_KEY_FP="00:11" cm setup)"; check "setup refuses a same-name key that is not this computer's" has "not this folder's key"
printf 'SERVER_TYPES="cx53 cpx62"\n' >> "$CM_HOME/.env"; run status
check "an old SERVER_TYPES in .env is ignored, with a note" has "SERVER_TYPES in"
sed -e '/^SERVER_TYPES=/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"

echo "== init and projects"
APP="$WORK/my app"; mkdir -p "$APP"; printf '{"name":"x"}\n' > "$APP/package.json"
run init "$APP"
check "init succeeds" has "INIT_OK: project 'my-app'"
check "init derives the name from the folder" grep -q '^PROJECT_NAME=my-app$' "$APP/.cloudmule/config.sh"
check "init copies the example job" test -f "$APP/.cloudmule/jobs/example.sh"
check "init adds a note to the project's CLAUDE.md" grep -q 'cloudmule' "$APP/CLAUDE.md"
run init "$APP"
check "init again does not duplicate the note" bash -c "[ \"\$(grep -c 'Heavy work: cloudmule' '$APP/CLAUDE.md')\" = 1 ]"
run projects; check "projects lists it" has "my-app"
mkdir -p "$WORK/elsewhere/my-app"; run init "$WORK/elsewhere/my-app"
check "a second project with the same name is refused" has "already registered"
mkdir -p "$CM_HOME/inner"; run init "$CM_HOME/inner"; rm -rf "$CM_HOME/inner"
check "a project inside cloudmule's folder is refused" has "cannot live inside"
REPO2="$WORK/repo2"; mkdir -p "$REPO2"; git -C "$REPO2" init -q
run init "$REPO2" --local --name repo2
check "--local keeps .cloudmule/ out of git" grep -qx '.cloudmule/' "$REPO2/.git/info/exclude"
check "--local leaves git status clean and no CLAUDE.md" \
  bash -c "[ -z \"\$(git -C '$REPO2' status --porcelain)\" ] && [ ! -f '$REPO2/CLAUDE.md' ]"

echo "== safety checks"
touch "$APP/.cloudmule/.env"; run job my-app example; rm "$APP/.cloudmule/.env"
check "refuses to run with a .env inside .cloudmule/" has "look like secrets"
echo 'HCLOUD_TOKEN=abc' > "$APP/.cloudmule/jobs/leak.sh"; run job my-app example; rm "$APP/.cloudmule/jobs/leak.sh"
check "refuses to run with a token line inside .cloudmule/" has "look like secrets"
cp "$APP/.cloudmule/config.sh" "$WORK/config.bak"
sed 's/^MODULES=.*/MODULES="node@24.15.0 nosuchmodule"/' "$WORK/config.bak" > "$APP/.cloudmule/config.sh"
run job my-app example; cp "$WORK/config.bak" "$APP/.cloudmule/config.sh"
check "refuses an unknown module" has "unknown module 'nosuchmodule'"
run job my-app example
check "a job needs the server running" has "is not running"

# ---------------------------------------------------------------- choosing the server
# A video project: ffmpeg makes it x86-only; it asks for 8 GB.
VID="$WORK/videos"; mkdir -p "$VID"
cm init "$VID" --name videos >/dev/null
sed -e 's/^MODULES=.*/MODULES="node@24.15.0 ffmpeg chrome-libs"/' -e 's/^# MIN_RAM_GB=8 .*/MIN_RAM_GB=8   # renders/' \
  "$VID/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$VID/.cloudmule/config.sh"

row() { printf '%s\n' "$OUT" | grep -E "^$1 " ; }   # the table row of one server type
row_has() { row "$1" | grep -F -- "$2" >/dev/null; }
row_plain_fit() { row "$1" | grep -E ' fits$' >/dev/null; }   # fits, with no disk-floor warning

echo "== servers (saved workspace from a 640 GB disk)"
run servers videos
check "servers succeeds" test "$RC" = 0
check "with no server running, it starts with the guide to choosing" has "How to choose"
check "the guide covers shared and dedicated CPUs" has "dedicated (CCX)"
check "the guide explains the disk floor" has "raises the floor for every later server"
check "it shows the disk floor and where it comes from" has "Disk floor: 640 GB"
check "it says only --fresh lowers the disk floor" has "only --fresh lowers it"
check "it shows the project's needs and their source" has "RAM >= 8 GB (config)"
check "it derives the architecture from the modules" has "CPU architecture: x86 (from its MODULES)"
check "cpx62 fits, with no disk-floor warning" row_has cpx62 "fits (last choice)"
check "a bigger disk says it raises the disk floor and what is lost" row_has ccx63 "fits; raises disk floor 640 -> 960 GB (1 type lost)"
check "cx23 does not fit, with the reasons" has "no: ram < 8 GB; below disk floor 640 GB (or --fresh)"
check "arm types are marked as the wrong architecture" has "arch arm (project needs x86)"
check "unavailable types are marked" has "unavailable"
check "it recommends the cheapest fitting type" has "RECOMMENDED: cpx62 hel1 0.2083"
check "it shows the last choice recorded on Hetzner" has "Last choice: cpx62 (by youtube, 2026-11-14)"
check "the row of the last choice is marked" row_has cpx62 "fits (last choice)"
check "it names the cheapest type the disk floor shuts out, with the saving" \
  has "Cheaper with --fresh: cpx32 0.0569 EUR/h (saves 0.1514 EUR/h)"
check "the escape line says what --fresh costs once" has "lowers the disk floor to 160 GB"
run servers videos --fresh
check "servers --fresh ignores the workspace" has "Disk floor: none (--fresh ignores the saved workspace)"
check "servers --fresh recommends a smaller server" has "RECOMMENDED: cpx32 hel1"
check "servers --fresh has no escape line" hasnt "Cheaper with --fresh"
run servers
check "servers without a project applies no project needs" bash -c "! printf '%s' \"\$1\" | grep -q 'Project ' " _ "$OUT"
check "servers without a project still recommends" has "RECOMMENDED: cpx62"
check "servers without a project gives no escape advice (no real needs to meet)" hasnt "Cheaper with --fresh"
BIG="$WORK/big"; mkdir -p "$BIG"; cm init "$BIG" --name big >/dev/null
printf 'MIN_RAM_GB=32\nMODULES="ffmpeg"\n' >> "$BIG/.cloudmule/config.sh"
run servers big
check "nothing cheaper shut out by the disk floor: no escape line" hasnt "Cheaper with --fresh"

echo "== servers (no workspace yet: this choice sets the disk floor)"
OUT="$(FAKE_HC_SCENARIO=empty cm servers videos)"
check "with no workspace, it says the server created now sets the disk floor" has "the server you create now sets the disk floor"
check "no row warns about losing nothing" hasnt "(0 types lost)"
check "the smallest fitting disk (ccx13, 80 GB) carries no warning" row_plain_fit ccx13
check "a bigger disk says which disk floor it would set and what is lost" \
  row_has cpx42 "fits; sets disk floor to 320 GB (5 types lost)"
check "even the cheapest type is warned when its disk is bigger than needed" \
  row_has cpx32 "fits; sets disk floor to 160 GB (2 types lost)"
check "with no workspace there is no escape line" hasnt "Cheaper with --fresh"
check "with no record of a choice, servers says so" has "Last choice: none yet"

echo "== servers (the server is running: no choice now)"
OUT="$(FAKE_HC_SCENARIO=running cm servers videos)"
check "a running server: no guide" hasnt "How to choose"
check "a running server: the next disk floor is its own disk" has "Disk floor next time: 80 GB"
check "a running server: no escape advice (start would join it)" hasnt "Cheaper with --fresh"

echo "== start --dry-run"
run start videos --dry-run
check "creating the server without --type is refused" bash -c "[ $RC != 0 ]"
check "the refusal asks for a type" has "NEEDS_SERVER_TYPE"
check "the refusal names the last choice recorded on Hetzner" has "Last choice: cpx62 (by youtube, 2026-11-14)"
run start videos --type cpx62 --dry-run
check "with --type it would create exactly that type" has "WOULD_CREATE: cpx62 hel1 1000001 0.2083"
check "the server would carry the choice as labels (type, project, date)" \
  has "WOULD_LABEL: chosen-type=cpx62 chosen-by=videos chosen-at=$(date +%Y-%m-%d)"
run start videos --type cx23 --dry-run
check "a type that cannot restore the workspace is refused" bash -c "[ $RC != 0 ]"
check "the refusal explains why" has "NO_FITTING_SERVER: cx23: ram < 8 GB; below disk floor 640 GB (or --fresh)"
run start videos --type cpx42 --fresh --dry-run
check "--fresh allows a smaller type, from plain Ubuntu" has "WOULD_CREATE: cpx42 hel1 ubuntu-24.04"
run start videos --type cpx62 --location nbg1 --dry-run
check "--location picks the location" has "WOULD_CREATE: cpx62 nbg1 1000001"
run start videos --type cpx62 --location mars1 --dry-run
check "an unknown location is refused" has "is not in LOCATIONS"
printf 'SERVER_TYPES="ccx63 cpx62"\n' >> "$VID/.cloudmule/config.sh"
run start videos --type cpx62 --dry-run
check "an old SERVER_TYPES in a project is ignored, with a note" has "SERVER_TYPES in"
check "an old SERVER_TYPES does not choose the server" has "WOULD_CREATE: cpx62 hel1"
OUT="$(LOCATIONS="nbg1" cm servers videos)"
check "a setting in the environment wins over .env" bash -c "printf '%s\n' \"\$1\" | grep -x 'Locations: nbg1' >/dev/null" _ "$OUT"
OUT="$(FAKE_HC_SCENARIO=empty cm start my-app --dry-run)"
check "with no record of a choice, the refusal says so" has "Last choice: none yet"
mkdir -p "$WORK/trail"; cm init "$WORK/trail" --name trail- >/dev/null
run start trail- --type cpx62 --dry-run
check "the chosen-by label is a value Hetzner accepts (alphanumeric at both ends)" has "chosen-by=trail chosen-at="
OUT="$(FAKE_HC_SCENARIO=running cm start videos --dry-run)"
check "a running server is joined, with its type" has "already running (203.0.113.10, cpx22"
check "joining says who chose the running server" has "chosen by charlio on 2026-11-14"
check "a running server below the project's needs is reported" has "SERVER_BELOW_REQUIREMENTS: ram < 8 GB"
check "joining needs no choice" has "WOULD_JOIN: cloudmule"
OUT="$(FAKE_HC_SCENARIO=running cm start videos --fresh --dry-run)"
check "--fresh is refused while the server is running" has "--fresh needs the server to be off"

echo "== oneshot (creates the server only with --type)"
run oneshot videos example
check "oneshot without --type is refused" has "NEEDS_SERVER_TYPE"
check "oneshot without --type never asks Hetzner to create a server" bash -c "! grep '^server create ' '$FAKE_HC_LOG' >/dev/null"
run oneshot videos --type cx23 example
check "oneshot reads --type before the job name" has "NO_FITTING_SERVER: cx23"
echo "== usage (one summary line per job, kept USAGE_KEEP_DAYS; job logs kept LOG_KEEP_DAYS)"
# usage.tsv lines (tab-separated): date project target job type seconds peak_mb ram_mb cpu_s vcpus exit stall_s
NOW="$(date +%Y-%m-%dT%H:%M)"
{ printf '2020-01-01T10:00\tcharlio\t-\ttest\tcpx62\t60\t30000\t32105\t60\t16\t0\t0\n'
  printf '%s\tcharlio\t-\ttest\tcpx62\t600\t6144\t32105\t1800\t16\t0\t0\n' "$NOW"
  printf '%s\tcharlio\t-\ttest\tcpx62\t300\t4096\t32105\t300\t16\t0\t2\n' "$NOW"
  printf '%s\tcharlio\t-\tapp\tcpx62\t120\tn/a\t32105\tn/a\t16\t1\tn/a\n' "$NOW"
  printf '%s\tvideos\tep-01\trender\tccx33\t1800\t20480\t32105\t12600\t8\t0\t45\n' "$NOW"
  printf '%s\tvideos\tep-02\trender\tccx33\t900\t10240\t32105\t3600\t8\t0\t0\n' "$NOW"
  printf 'a line someone edited by hand\n'
} > "$CM_HOME/logs/usage.tsv"
touch -t 202001010000 "$CM_HOME/logs/charlio-test-20200101-0000.log"
touch "$CM_HOME/logs/charlio-test-recent.log"
run usage
check "usage succeeds (and ignores a line edited by hand)" test "$RC" = 0
check "usage counts each job's runs and shows its highest peak RAM against the server's nominal RAM" \
  bash -c "printf '%s\n' \"\$1\" | grep -E '^charlio +test +2 +6\.0 / 32 GB' >/dev/null" _ "$OUT"
check "usage shows how long a job waited for memory" bash -c "printf '%s\n' \"\$1\" | grep -E '^charlio +test .* 2 s ' >/dev/null" _ "$OUT"
check "usage shows typical and highest cores used, against the vCPUs" has "2.0 typ, 3.0 max / 16"
check "usage shows the longest run" has "10 min"
check "a job measured without cgroup data shows n/a" bash -c "printf '%s\n' \"\$1\" | grep -E '^charlio +app .*n/a' >/dev/null" _ "$OUT"
check "usage groups a job's runs across targets" bash -c "printf '%s\n' \"\$1\" | grep -E '^videos +render +2 +20\.0 / 32 GB +45 s' >/dev/null" _ "$OUT"
check "usage names the highest peak RAM overall" has "Highest peak RAM: 20.0 GB (videos ep-01 render)"
check "usage explains that peak RAM includes file cache and what RAM WAIT means" has "near 0 s means the RAM was enough"
check "usage warns that simultaneous jobs add up" has "add up"
check "lines older than USAGE_KEEP_DAYS are ignored" hasnt "29.3"
check "lines older than USAGE_KEEP_DAYS are dropped from the file" bash -c "! grep '^2020-' '$CM_HOME/logs/usage.tsv' >/dev/null"
check "job logs older than LOG_KEEP_DAYS are deleted" test ! -e "$CM_HOME/logs/charlio-test-20200101-0000.log"
check "recent job logs are kept" test -e "$CM_HOME/logs/charlio-test-recent.log"
run usage videos
check "usage <project> shows only that project" \
  bash -c "printf '%s\n' \"\$1\" | grep render >/dev/null && ! printf '%s\n' \"\$1\" | grep '^charlio' >/dev/null" _ "$OUT"
run usage videos ep-02
check "usage <project> <target> shows only that target" bash -c "printf '%s\n' \"\$1\" | grep -E '^videos +render +1 +10\.0' >/dev/null" _ "$OUT"
run usage nobody
check "usage of a project with no records says so" has "No job usage recorded yet"

echo "== gpus (RunPod: the GPUs available now, against the project and the caps)"
scenario
run gpus videos
check "gpus without a RunPod key asks for it (pasted by the user)" has "RUNPOD_API_KEY is missing"
printf 'RUNPOD_API_KEY=%s\n' "$RP_KEY" >> "$CM_HOME/.env"
# a GPU project: WebGL frames in headless Chrome
GFX="$WORK/gfx"; mkdir -p "$GFX"; cm init "$GFX" --name gfx >/dev/null
sed -e 's/^# NEEDS_GPU=.*/NEEDS_GPU=graphics/' -e 's/^# MIN_VRAM_GB=.*/MIN_VRAM_GB=8/' \
  -e 's/^MODULES=.*/MODULES="node@24.15.0"/' -e 's/^INSTALL_CMD=.*/INSTALL_CMD=""/' \
  "$GFX/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$GFX/.cloudmule/config.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho rendering\necho "CLOUDMULE_RESULT out/frame.png"\n' > "$GFX/.cloudmule/jobs/render.sh"
run gpus gfx
check "gpus succeeds" test "$RC" = 0
check "gpus says what the project needs" has "Project gfx needs: a GPU for graphics work (NEEDS_GPU=graphics); VRAM >= 8 GB (config)"
check "gpus shows the caps from .env" has "at most 0.70 USD/h per pod"
check "gpus shows today's spend and what is left" has "Today's GPU spend: 0.00 USD, plus 0.00 USD worst case of pods running now: 2.00 USD left"
check "gpus says the standing approval is off by default" has "Standing approval: off"
check "gpus says there is no last choice yet" has "Last choice: none yet"
check "a fitting GPU shows its price and worst case per pod" row_has "NVIDIA A40" "48 GB  SECURE      0.59    0.393  MEDIUM  fits"
check "a GPU with too little VRAM does not fit" row_has "NVIDIA RTX A2000" "no: VRAM < 8 GB"
check "a GPU above the hourly cap does not fit" row_has "NVIDIA H100 80GB HBM3" "no: above the hourly cap 0.70 USD/h"
check "a GPU that is not NVIDIA does not fit" row_has "AMD Instinct MI300X OAM" "no: not NVIDIA"
check "an unavailable GPU says so" row_has "NVIDIA RTX A4000" "no: none available now"
check "COMMUNITY offers are listed as unusable (no public SSH)" row_has "NVIDIA GeForce RTX 5080" "no: no public SSH (community cloud)"
check "the recommendation is the cheapest fitting GPU with MEDIUM or HIGH availability, not a cheaper LOW one" \
  has "RECOMMENDED: NVIDIA A40 SECURE 0.59"
check "every RunPod request carried the key" bash -c "! grep ' BAD$' '$RP/requests.log' >/dev/null"
run gpus gfx --cloud community
check "--cloud community lists only COMMUNITY offers" bash -c "! printf '%s\n' \"\$1\" | grep ' SECURE ' >/dev/null" _ "$OUT"
OUT="$(RUNPOD_MAX_USD_PER_HOUR=5 RUNPOD_STANDING_APPROVAL=1 cm gpus gfx)"; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a cap given in the environment cannot raise the one in .env" row_has "NVIDIA H100 80GB HBM3" "above the hourly cap 0.70"
check "a standing approval given in the environment does not count" has "Standing approval: off"
sed 's/^MIN_VRAM_GB=8$/MIN_VRAM_GB=40/' "$GFX/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$GFX/.cloudmule/config.sh"
run gpus gfx
check "MIN_VRAM_GB rules out smaller GPUs" row_has "NVIDIA L4" "no: VRAM < 40 GB"
sed 's/^MIN_VRAM_GB=40$/MIN_VRAM_GB=8/' "$GFX/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$GFX/.cloudmule/config.sh"
run gpus my-app
check "a project that does not say whether it needs a GPU is flagged, for the agent to ask" has "NEEDS_GPU is not set"
# usage.tsv: a GPU pod deleted today that cost 1.80 USD (date … stall_s provider billed_s cost_usd)
printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t1.8000\n' "$NOW" >> "$CM_HOME/logs/usage.tsv"
run gpus gfx
check "today's spend comes from the usage lines" has "Today's GPU spend: 1.80 USD"
check "a GPU whose worst case passes what is left today does not fit" row_has "NVIDIA A40" "passes today's cap (0.20 left)"
check "with no MEDIUM/HIGH GPU left, the cheapest fitting one is recommended" has "RECOMMENDED: NVIDIA RTX 2000 Ada Generation SECURE 0.24"
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"
scenario '{"catalog_status": 403}'; run gpus gfx
check "a key without catalog permission is refused with the fix" has "\"catalog read\" permission"
check "the 403 makes gpus fail" test "$RC" != 0
scenario
run gpus
check "gpus without a project applies no VRAM need" row_has "NVIDIA RTX A2000" "fits"

echo "== gpu (one job on a RunPod GPU pod, deleted at the end)"
posts() { grep -c '^POST /v2/pods ' "$RP/requests.log" 2>/dev/null || true; }
pods_left() { "$PY" -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["pods"]))' "$(winpath "$RP/state.json")" 2>/dev/null || echo 0; }
FAKE_SSH_LOG="$WORK/ssh.log"; export FAKE_SSH_LOG
gpu_run() { OUT="$(PATH="$REPO/tests/fake-ssh:$PATH" cm gpu "$@")"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"; }
scenario; : > "$RP/requests.log"
run gpu gfx render
check "gpu without --gpu is refused, asking for the user's choice" has "NEEDS_GPU_CHOICE"
run gpu gfx --gpu "NVIDIA A40" render
check "gpu without standing approval or --approved is refused" has "NEEDS_APPROVAL"
check "the approval refusal fails" test "$RC" != 0
printf 'NEEDS_GPU=0\n' >> "$BIG/.cloudmule/config.sh"; run gpu big --gpu "NVIDIA A40" --approved example
check "a project that says NEEDS_GPU=0 is refused" has "NO_GPU_NEEDED"
run gpu gfx --gpu "NVIDIA A40" --dry-run render
check "--dry-run says what it would create, with the worst case" has "WOULD_CREATE: NVIDIA A40 SECURE 0.59 0.393"
run gpu gfx --gpu "NVIDIA H100 80GB HBM3" --approved render
check "a GPU above the hourly cap is refused" has "ABOVE_HOURLY_CAP"
printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t1.9500\n' "$NOW" >> "$CM_HOME/logs/usage.tsv"
run gpu gfx --gpu "NVIDIA A40" --approved render
check "a pod whose worst case passes today's cap is refused" has "DAILY_CAP_REACHED"
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"
check "no refusal ever asked RunPod to create a pod" test "$(posts)" = 0

# candidates in order: the first is not available, the second is billed above the cap (deleted at once), the
# third runs the job
scenario '{"unavailable": ["NVIDIA RTX PRO 4000 Blackwell"], "cost": {"NVIDIA L4": 0.89}}'; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_run gfx --gpu "NVIDIA RTX PRO 4000 Blackwell,NVIDIA L4,NVIDIA A40" --approved render
check "gpu runs the job on the pod" has "GPU_OK: render"
check "an unavailable candidate is skipped" has "NVIDIA RTX PRO 4000 Blackwell: not created (There are no longer any instances"
check "a pod billed above the hourly cap is deleted at once" has "NVIDIA L4: RunPod charges 0.89 USD/h, above the hourly cap"
check "the candidates were tried in order" bash -c "grep -o '\"id\": \"NVIDIA[^\"]*\"' '$RP/requests.log' | tr '\n' '|' \
  | grep -F '\"id\": \"NVIDIA RTX PRO 4000 Blackwell\"|\"id\": \"NVIDIA L4\"|\"id\": \"NVIDIA A40\"|' >/dev/null"
check "the above-cap pod was deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
check "it reports the GPU and price used" has "GPU pod fakepod2 created: NVIDIA A40, 0.59 USD/h (SECURE)"
check "the pod is created with the SSH key and the graphics capability, on the default image" \
  bash -c "grep -F '\"PUBLIC_KEY\": \"ssh-ed25519 ' '$RP/requests.log' | grep -F 'NVIDIA_DRIVER_CAPABILITIES\": \"all' \
    | grep -F 'runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04' >/dev/null"
check "the pod is named after the project and the job" grep -qF '"name": "cloudmule-gfx-render"' "$RP/requests.log"
check "the pod guard starts first thing after SSH" bash -c "sed -n 2p '$FAKE_SSH_LOG' | grep -F 'pod-guard.sh' >/dev/null"
check "graphics projects get chrome-libs and gpu-graphics before their own modules" \
  bash -c "grep -o 'module-[a-z-]*' '$FAKE_SSH_LOG' | uniq | tr '\n' ' ' | grep 'module-chrome-libs module-gpu-graphics module-node' >/dev/null"
check "graphics projects check that Chrome renders on the GPU before uploading" \
  bash -c "grep -n -e '^cloudmule-webgl-check\$' -e 'find . ' '$FAKE_SSH_LOG' | head -1 | grep webgl >/dev/null"
check "the job's results are downloaded" has "RESULT: $GFX/out/frame.png"
check "the pod is deleted when the job ends" grep -q '^DELETE /v2/pods/fakepod2 ' "$RP/requests.log"
check "it reports what the pod cost" has "GPU pod fakepod2 deleted: NVIDIA A40, 0.59 USD/h"
check "no pod is left" test "$(pods_left)" = 0
check "the pod's usage line records the GPU, provider and cost" \
  bash -c "awk -F'\t' '\$4==\"render\" && \$5==\"NVIDIA A40\" && \$6==\"90\" && \$13==\"runpod\" && \$15 ~ /^[0-9.]+\$/' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
check "the above-cap pod's few seconds are recorded too" \
  bash -c "awk -F'\t' '\$5==\"NVIDIA L4\" && \$13==\"runpod\"' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
check "the throwaway SSH key is deleted with the pod" bash -c "! ls '$CM_HOME/keys' | grep '^pod-' >/dev/null"
check "no pod record is left" bash -c "[ -z \"\$(ls '$CM_HOME/logs/runpod' 2>/dev/null)\" ]"
check "the RunPod key is never sent to the pod" bash -c "! grep -F '$RP_KEY' '$RP/requests.log' '$FAKE_SSH_LOG' >/dev/null"
run gpus gfx
check "gpus then shows the last GPU choice" has "Last choice: NVIDIA A40 SECURE (by gfx, $(date +%Y-%m-%d))"
check "the row of the last choice is marked" row_has "NVIDIA A40" "fits (last choice)"

scenario '{"no_public_ssh": true}'; : > "$RP/requests.log"
OUT="$(RUNPOD_BOOT_SECONDS=2 RUNPOD_POLL_SECONDS=1 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a pod without public SSH is refused with NO_PUBLIC_SSH" has "NO_PUBLIC_SSH"
check "...and deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
check "...and the command fails" test "$RC" != 0

scenario; : > "$RP/requests.log"
OUT="$(FAKE_SSH_FAIL=render PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a failing job makes gpu fail" test "$RC" != 0
check "a failing job still deletes the pod" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
check "no pod is left after a failure" test "$(pods_left)" = 0

scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
OUT="$(FAKE_SSH_WEBGL=software PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "Chrome rendering in software stops the run (GPU_NOT_USED)" has "GPU_NOT_USED"
check "...before the project is uploaded" bash -c "! grep 'find . ' '$FAKE_SSH_LOG' >/dev/null"
check "...and the pod is deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"

scenario; : > "$RP/requests.log"
OUT="$(FAKE_SSH_DOWN=1 RUNPOD_BOOT_SECONDS=2 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a pod that never answers SSH is refused" has "did not answer over SSH"
check "...and deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"

# the local watchdog: with a 3-second time cap, it deletes the pod while the command is still waiting for SSH
scenario; : > "$RP/requests.log"
printf 'RUNPOD_MAX_MINUTES=0.05\n' >> "$CM_HOME/.env"
OUT="$(FAKE_SSH_DOWN=1 RUNPOD_BOOT_SECONDS=10 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
sed '/^RUNPOD_MAX_MINUTES=0.05$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"
check "the watchdog deletes the pod at the time cap, even while the command is busy" \
  bash -c "[ \"\$(grep -c '^DELETE /v2/pods/fakepod1 ' '$RP/requests.log')\" = 1 ] && ! printf '%s' \"\$1\" | grep 'GPU pod fakepod1 deleted' >/dev/null" _ "$OUT"
check "...and records what the pod cost" \
  bash -c "awk -F'\t' '\$13==\"runpod\"' '$CM_HOME/logs/usage.tsv' | tail -1 | awk -F'\t' '\$14 < 10' | grep . >/dev/null"

scenario; : > "$RP/requests.log"
printf 'RUNPOD_STANDING_APPROVAL=1\n' >> "$CM_HOME/.env"
gpu_run gfx --gpu "NVIDIA A40" render
check "with a standing approval in .env, gpu runs without --approved" has "GPU_OK: render"
sed '/^RUNPOD_STANDING_APPROVAL=1$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"

echo "== usage and status with GPU pods"
run usage gfx
check "usage shows what a GPU job cost and how long its pods existed" \
  bash -c "printf '%s\n' \"\$1\" | grep -E '^gfx +render .* USD / [0-9]+ min +NVIDIA A40 \(runpod\)' >/dev/null" _ "$OUT"
check "usage sums up the GPU spend" has "GPU pods (RunPod): "
check "usage says the GPU cost is an estimate" has "RunPod's billing is authoritative"
run usage
check "Hetzner jobs have no GPU cost" bash -c "printf '%s\n' \"\$1\" | grep -E '^videos +render .* - +ccx33' >/dev/null" _ "$OUT"
# pods in the account: a cloudmule pod up 2 h (an orphan), one up 5 min, one whose age the API does not give, and
# a pod that is not cloudmule's
scenario '{"pods": [
  {"id": "old1", "name": "cloudmule-old-render", "cost": 0.59, "gpu": {"id": "NVIDIA A40"}, "runtime": {"uptimeInSeconds": 7200}},
  {"id": "young1", "name": "cloudmule-gfx-render", "cost": 0.59, "gpu": {"id": "NVIDIA A40"}, "runtime": {"uptimeInSeconds": 300}},
  {"id": "noage1", "name": "cloudmule-gfx-probe", "cost": 0.24, "gpu": {"id": "NVIDIA RTX 2000 Ada Generation"}},
  {"id": "other1", "name": "my-notebook", "cost": 0.69, "gpu": {"id": "NVIDIA L4"}, "runtime": {"uptimeInSeconds": 7200}}]}'
: > "$RP/requests.log"
OUT="$(FAKE_HC_SCENARIO=empty cm status)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "status lists the RunPod pods" has "== RunPod GPU pods"
check "status lists a running cloudmule pod with its GPU, price and age" has "cloudmule-gfx-render (young1): NVIDIA A40, 0.59 USD/h, up 5 min"
check "status deletes a cloudmule pod past its time cap and says so" has "ORPHAN_DELETED: cloudmule-old-render (old1)"
check "...through the API" grep -q '^DELETE /v2/pods/old1 ' "$RP/requests.log"
check "status warns about a pod that is not cloudmule's, without touching it" has "WARNING: my-notebook (other1) is not cloudmule's"
check "...and never deletes it" bash -c "! grep '^DELETE /v2/pods/other1 ' '$RP/requests.log' >/dev/null"
check "status succeeds when every pod could be checked" test "$RC" = 0
check "a cloudmule pod of unknown age is kept, and timed from now" \
  has "cloudmule-gfx-probe (noage1): NVIDIA RTX 2000 Ada Generation, 0.24 USD/h, up ? min (RunPod gives no age; first seen 0 min ago)"
check "...and remembered, so a later check can reap it" test -f "$CM_HOME/logs/runpod/noage1.json"
check "the orphan's cost counts in the usage lines" \
  bash -c "awk -F'\t' '\$4==\"cloudmule-old-render\" && \$13==\"runpod\"' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
rm -f "$CM_HOME/logs/runpod/noage1.json"; scenario
OUT="$(RUNPOD_API_BASE=http://127.0.0.1:9/v2 FAKE_HC_SCENARIO=empty cm status)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "status says when it could not check the RunPod pods" has "RUNPOD_UNKNOWN"
check "...still shows the Hetzner part" has "== Snapshots"
check "...and fails, so nobody reads it as all clear" test "$RC" != 0
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"

echo "== end --keep (the server cannot be reached: the save must still happen through the API)"
: > "$WORK/before.log"; cp "$FAKE_HC_LOG" "$WORK/before.log"
OUT="$(FAKE_HC_SCENARIO=running cm end videos --keep)"
NEW="$(tail -n +"$(( $(wc -l < "$WORK/before.log") + 1 ))" "$FAKE_HC_LOG")"
calls() { printf '%s\n' "$NEW" | grep -E "$1" >/dev/null; }
check "end --keep snapshots the server with cloudmule's labels" \
  calls '^server create-image --type snapshot .*--label managed-by=cloudmule --label role=workspace --label scope=shared cloudmule$'
check "end --keep copies the choice onto the snapshot" \
  calls '^server create-image .*--label chosen-type=cpx22 --label chosen-by=charlio --label chosen-at=2026-11-14 '
check "end --keep keeps only the newest workspace snapshot" calls '^image delete 1000001$'
check "end --keep does not delete the newest snapshot" bash -c "! printf '%s\n' \"\$1\" | grep -q '^image delete 1000002'" _ "$NEW"
check "end --keep deletes the server" calls '^server delete cloudmule$'
check "no test ever asked Hetzner to create a server" bash -c "! grep -q '^server create ' '$FAKE_HC_LOG'"
check "the RunPod key never appears in any output" bash -c "! grep -F '$RP_KEY' '$ALL_OUT' >/dev/null"
check "every Hetzner call was one the fake knows" bash -c "! grep -q '^UNHANDLED' '$FAKE_HC_LOG'"

echo
echo "RESULT: $PASSES passed, $FAILS failed, $SKIPS skipped"
[ "$FAILS" = 0 ]
