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
run gpus gfx --all
check "gpus succeeds" test "$RC" = 0
check "gpus says what the project needs" has "Project gfx needs: a GPU for graphics work (NEEDS_GPU=graphics); VRAM >= 8 GB (config)"
check "gpus shows the caps from .env" has "at most 0.70 USD/h per pod"
check "gpus shows today's spend and what is left" has "Today's GPU spend: 0.00 USD, plus 0.00 USD worst case of pods running now: 2.00 USD left"
check "gpus says the standing approval is off by default" has "Standing approval: off"
check "gpus says there is no last choice yet" has "Last choice: none yet"
check "a fitting GPU shows its price and worst case per pod" row_has "NVIDIA A40" "48 GB     9   50 GB  SECURE      0.59    0.393  MEDIUM  fits"
check "a GPU with too little VRAM does not fit" row_has "NVIDIA RTX A2000" "no: VRAM < 8 GB"
check "a GPU above the hourly cap does not fit" row_has "NVIDIA H100 80GB HBM3" "no: above the hourly cap 0.70 USD/h"
check "a GPU that is not NVIDIA does not fit" row_has "AMD Instinct MI300X OAM" "no: not NVIDIA"
check "an unavailable GPU says so" row_has "NVIDIA RTX A4000" "no: none available now"
check "a MIG slice does not fit graphics work (no Vulkan/OpenGL)" row_has "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 1g.24gb" "no: MIG slice"
check "a GPU listed at price 0 (not offered) is left out" hasnt "Tesla V100-PCIE-16GB"
check "COMMUNITY offers are listed as unusable (no public SSH)" row_has "NVIDIA GeForce RTX 5080" "no: no public SSH (community cloud)"
check "the recommendation is the cheapest fitting GPU with MEDIUM or HIGH availability, not a cheaper LOW one" \
  has "RECOMMENDED: NVIDIA A40 SECURE 0.59"
check "every RunPod request carried the key" bash -c "! grep ' BAD$' '$RP/requests.log' >/dev/null"
run gpus gfx --cloud community --all
check "--cloud community lists only COMMUNITY offers" bash -c "! printf '%s\n' \"\$1\" | grep ' SECURE ' >/dev/null" _ "$OUT"
OUT="$(RUNPOD_MAX_USD_PER_HOUR=5 RUNPOD_STANDING_APPROVAL=1 cm gpus gfx --all)"; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a cap given in the environment cannot raise the one in .env" row_has "NVIDIA H100 80GB HBM3" "above the hourly cap 0.70"
check "a standing approval given in the environment does not count" has "Standing approval: off"
sed 's/^MIN_VRAM_GB=8$/MIN_VRAM_GB=40/' "$GFX/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$GFX/.cloudmule/config.sh"
run gpus gfx --all
check "MIN_VRAM_GB rules out smaller GPUs" row_has "NVIDIA L4" "no: VRAM < 40 GB"
sed 's/^MIN_VRAM_GB=40$/MIN_VRAM_GB=8/' "$GFX/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$GFX/.cloudmule/config.sh"
run gpus my-app
check "a project that does not say whether it needs a GPU is flagged, for the agent to ask" has "NEEDS_GPU is not set"
# usage.tsv: a GPU pod deleted today that cost 1.80 USD (date … stall_s provider billed_s cost_usd)
printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t1.8000\n' "$NOW" >> "$CM_HOME/logs/usage.tsv"
run gpus gfx --all
check "today's spend comes from the usage lines" has "Today's GPU spend: 1.80 USD"
check "a GPU whose worst case passes what is left today does not fit" row_has "NVIDIA A40" "passes today's cap (0.20 left)"
check "with no MEDIUM/HIGH GPU left, the cheapest fitting one is recommended" has "RECOMMENDED: NVIDIA RTX 2000 Ada Generation SECURE 0.24"
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"
scenario '{"catalog_status": 403}'; run gpus gfx
check "a key without catalog permission is refused with the fix" has "\"catalog read\" permission"
check "the 403 makes gpus fail" test "$RC" != 0
scenario
run gpus --all
check "gpus without a project applies no VRAM need" row_has "NVIDIA RTX A2000" "fits"
check "...nor rules out MIG slices (only graphics work needs a whole GPU)" row_has "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 1g.24gb" "fits"

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
run gpu big --gpu "NVIDIA A40" --approved example
check "a project that does not say what GPU work it does is refused (no silent CPU fallback)" has "NEEDS_GPU_UNSET"
printf 'NEEDS_GPU=0\n' >> "$BIG/.cloudmule/config.sh"; run gpu big --gpu "NVIDIA A40" --approved example
check "a project that says NEEDS_GPU=0 is refused" has "NO_GPU_NEEDED"
run gpu gfx --gpu "NVIDIA A40" --cloud community --approved render
check "COMMUNITY pods are refused before anything is created" has "NO_FITTING_GPU: COMMUNITY pods have no public SSH"
run gpu gfx --gpu "NVIDIA A40" --dry-run render
check "--dry-run says what it would create, with the worst case" has "WOULD_CREATE: NVIDIA A40 SECURE 0.59 0.393"
run gpu gfx --gpu "NVIDIA H100 80GB HBM3" --approved render
check "a GPU above the hourly cap is refused" has "ABOVE_HOURLY_CAP"
run gpu gfx --gpu "NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 1g.24gb" --approved render
check "a MIG slice is refused for graphics work" has "NO_FITTING_GPU: NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 1g.24gb: MIG slice"
run gpu gfx --gpu "Tesla V100-PCIE-16GB" --approved render
check "a GPU the catalog lists at price 0 is refused as not offered" has "Tesla V100-PCIE-16GB: not offered"
printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t1.9500\n' "$NOW" >> "$CM_HOME/logs/usage.tsv"
run gpu gfx --gpu "NVIDIA A40" --approved render
check "a pod whose worst case passes today's cap is refused" has "DAILY_CAP_REACHED"
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"
check "no refusal ever asked RunPod to create a pod" test "$(posts)" = 0

# candidates in order: the first is not available, the second is billed above the cap (deleted at once), the
# third runs the job
# keys a killed run left behind: an old one (gone with its pod) and a young one (another session's pod may be starting)
for k in pod-20200101000000-aaaaaa pod-29990101000000-bbbbbb; do : > "$CM_HOME/keys/$k"; : > "$CM_HOME/keys/$k.pub"; done
touch -t 202001010000 "$CM_HOME/keys/pod-20200101000000-aaaaaa"
# an old key whose pod is still recorded (alive, or not yet accounted for): it and its measurement must stay
: > "$CM_HOME/keys/pod-20200101000000-cccccc"; : > "$CM_HOME/keys/pod-20200101000000-cccccc.measure"
touch -t 202001010000 "$CM_HOME/keys/pod-20200101000000-cccccc" "$CM_HOME/keys/pod-20200101000000-cccccc.measure"
mkdir -p "$CM_HOME/logs/runpod"
printf '{"id": "kept9", "run": "20200101000000-cccccc", "created": %s, "cost": 0.5, "gpu": "NVIDIA A40"}\n' \
  "$(date +%s)" > "$CM_HOME/logs/runpod/kept9.json"
scenario '{"unavailable": ["NVIDIA RTX PRO 4000 Blackwell"], "cost": {"NVIDIA L4": 0.89}}'; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_run gfx --gpu "NVIDIA RTX PRO 4000 Blackwell,NVIDIA L4,NVIDIA A40" --approved render
check "gpu runs the job on the pod" has "GPU_OK: render"
check "an unavailable candidate is skipped" has "NVIDIA RTX PRO 4000 Blackwell: not created (There are no longer any instances"
check "a pod billed above the hourly cap is deleted at once" has "NVIDIA L4: RunPod charges 0.89 USD/h, above the hourly cap"
check "the candidates were tried in order" bash -c "grep -o '\"id\": \"NVIDIA[^\"]*\"' '$RP/requests.log' | tr '\n' '|' \
  | grep -F '\"id\": \"NVIDIA RTX PRO 4000 Blackwell\"|\"id\": \"NVIDIA L4\"|\"id\": \"NVIDIA A40\"|' >/dev/null"
check "the above-cap pod was deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
check "it reports the GPU and price used" has "GPU pod fakepod2 created: NVIDIA A40, 0.59 USD/h (SECURE)"
check "the pod is created with the SSH key and the graphics capability, on the default graphics image" \
  bash -c "grep -F '\"PUBLIC_KEY\": \"ssh-ed25519 ' '$RP/requests.log' | grep -F 'NVIDIA_DRIVER_CAPABILITIES\": \"all' \
    | grep -F 'ghcr.io/brunochampion/cloudmule-gpu-graphics@sha256:' >/dev/null"
check "the pod carries its own time cap, for any computer's orphan check" grep -qF '"CLOUDMULE_MAX_MINUTES": "40"' "$RP/requests.log"
check "the pod is named after the project, the job and this run" grep -qE '"name": "cloudmule-gfx-render-[0-9a-f]{6}"' "$RP/requests.log"
check "the pod guard starts first thing after SSH" bash -c "sed -n 2p '$FAKE_SSH_LOG' | grep -F 'pod-guard.sh' >/dev/null"
check "graphics projects get chrome-libs and gpu-graphics before their own modules" \
  bash -c "grep -o 'module-[a-z-]*' '$FAKE_SSH_LOG' | uniq | tr '\n' ' ' | grep 'module-chrome-libs module-gpu-graphics module-node' >/dev/null"
check "graphics projects check that Chrome renders on the GPU before uploading" \
  bash -c "grep -n -e '^cloudmule-webgl-check' -e 'find . ' '$FAKE_SSH_LOG' | head -1 | grep webgl >/dev/null"
check "the job's results are downloaded" has "RESULT: $GFX/out/frame.png"
check "the pod is deleted when the job ends" grep -q '^DELETE /v2/pods/fakepod2 ' "$RP/requests.log"
check "it reports what the pod cost" has "GPU pod fakepod2 deleted: NVIDIA A40, 0.59 USD/h"
check "no pod is left" test "$(pods_left)" = 0
check "the pod's usage line records the GPU, provider and cost" \
  bash -c "awk -F'\t' '\$4==\"render\" && \$5==\"NVIDIA A40\" && \$6==\"90\" && \$13==\"runpod\" && \$15 ~ /^[0-9.]+\$/' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
check "the above-cap pod's few seconds are recorded too" \
  bash -c "awk -F'\t' '\$5==\"NVIDIA L4\" && \$13==\"runpod\"' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
check "an old pod key a killed run left behind is cleaned up" test ! -e "$CM_HOME/keys/pod-20200101000000-aaaaaa"
check "a young pod key (maybe another session's starting pod) is kept" test -e "$CM_HOME/keys/pod-29990101000000-bbbbbb"
check "an old key whose pod is still recorded is kept, with its measurement" \
  bash -c "[ -e '$CM_HOME/keys/pod-20200101000000-cccccc' ] && [ -e '$CM_HOME/keys/pod-20200101000000-cccccc.measure' ]"
rm -f "$CM_HOME/keys/pod-29990101000000-bbbbbb" "$CM_HOME/keys/pod-29990101000000-bbbbbb.pub" \
  "$CM_HOME/keys/pod-20200101000000-cccccc" "$CM_HOME/keys/pod-20200101000000-cccccc.measure" "$CM_HOME/logs/runpod/kept9.json"
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

echo "== gpu: correct pictures, measured runs (spec 0005)"
export FAKE_SSH_STATE="$WORK/ssh-state"; mkdir -p "$FAKE_SSH_STATE"
# gpu_env [VAR=value…]: `gpu gfx --gpu "NVIDIA A40" --approved render` with those settings and the fake ssh
gpu_env() { OUT="$(env "$@" PATH="$REPO/tests/fake-ssh:$PATH" bash "$CM_HOME/bin/cloudmule" gpu gfx --gpu "NVIDIA A40" --approved render 2>&1)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"; }
newest_log() { ls -t "$CM_HOME"/logs/"$1"-*.log 2>/dev/null | grep -v '\.gpu-watch\.log$' | head -1; }
cfg_drop() { sed "/^$2=/d" "$1/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$1/.cloudmule/config.sh"; }

scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_env
check "a clean graphics run ends GPU_OK" has "GPU_OK: render"
check "the default backend (GL over EGL) becomes the pod's Chrome flags" \
  grep -qF 'cloudmule-gpu-libs; cp -f /etc/cloudmule/chrome-gpu-flags.gl-egl /etc/cloudmule/chrome-gpu-flags' "$FAKE_SSH_LOG"
check "jobs get the Chrome flags, the ANGLE backend and where to tee Chrome's log" \
  bash -c "grep -F 'CLOUDMULE_CHROME_ANGLE=gl-egl' '$FAKE_SSH_LOG' | grep -F 'CLOUDMULE_CHROME_LOG=' | grep -F 'CLOUDMULE_CHROME_GPU_FLAGS=' >/dev/null"
check "the pod's CPUs and RAM come from its cgroup" has "POD_CPUS=9 POD_RAM_GB=50 (jobs: CLOUDMULE_CPUS"
check "jobs get CLOUDMULE_CPUS and CLOUDMULE_RAM_GB" \
  bash -c "grep -F 'CLOUDMULE_CPUS=9' '$FAKE_SSH_LOG' | grep -F 'CLOUDMULE_RAM_GB=50' >/dev/null"
check "jobs get a deadline before the pod's time cap (CLOUDMULE_DEADLINE)" grep -qE 'CLOUDMULE_DEADLINE=[0-9]{9,}' "$FAKE_SSH_LOG"
check "the watcher runs during the job" grep -qF 'gpu-watch.sh run /root/cloudmule/gpu-watch.log /root/cloudmule/jobs/gfx-render.log /root/cloudmule/chrome-gpu.log' "$FAKE_SSH_LOG"
check "the WebGL check runs again after the job, short (--quick)" grep -qE '^cloudmule-webgl-check --quick' "$FAKE_SSH_LOG"
check "the run's GPU, VRAM, CPU (of the pod's allotment) and RAM use are summed up" \
  has "GPU_USE mean=30% max=40% · VRAM max=5000/46068 MiB · CPU mean=50% of 9 vCPUs · RAM max=12.0/50 GiB"
check "...with the slots rule's hint" has "GPU_USE_HINT: every resource below 60%"
check "...and recorded in the pod's usage line" \
  bash -c "awk -F'\t' '\$13==\"runpod\" && \$16 ~ /^GPU_USE mean=30%/' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
log="$(newest_log gfx-render)"
check "the WebGL checks and the pod's numbers are appended to the job's local log" \
  bash -c "grep -F '== cloudmule-webgl-check' '$log' >/dev/null && grep -F 'GPU_USE mean=' '$log' >/dev/null && grep -F 'POD_CPUS=9' '$log' >/dev/null"
check "the watcher's samples are kept next to the job's log" bash -c "ls '$CM_HOME'/logs/gfx-render-*.gpu-watch.log >/dev/null"
check "no pod is left after a measured run" test "$(pods_left)" = 0

scenario; gpu_env FAKE_SSH_ALLOC=none
check "with no limits in the pod's cgroup, CPUs and RAM come from RunPod's catalog, and it says so" \
  has "POD_CPUS=9 POD_RAM_GB=50 (CPUs from RunPod's catalog"

printf 'GPU_GRAPHICS_BACKEND=vulkan\n' >> "$GFX/.cloudmule/config.sh"; scenario; : > "$FAKE_SSH_LOG"
gpu_env
check "GPU_GRAPHICS_BACKEND=vulkan selects the Vulkan flags, with a note" \
  bash -c "grep -F 'chrome-gpu-flags.vulkan /etc/cloudmule/chrome-gpu-flags' '$FAKE_SSH_LOG' >/dev/null && printf '%s' \"\$1\" | grep -F 'only if your page survives' >/dev/null" _ "$OUT"
cfg_drop "$GFX" GPU_GRAPHICS_BACKEND; printf 'GPU_GRAPHICS_BACKEND=metal\n' >> "$GFX/.cloudmule/config.sh"
gpu_env
check "an unknown Chrome backend is refused" has "GPU_GRAPHICS_BACKEND in"
cfg_drop "$GFX" GPU_GRAPHICS_BACKEND

scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_env FAKE_SSH_WEBGL=lost
check "a lost WebGL context stops the run before the upload (GPU_CONTEXT_LOST)" \
  bash -c "printf '%s' \"\$1\" | grep 'GPU_CONTEXT_LOST:' >/dev/null && ! grep 'find . ' '$FAKE_SSH_LOG' >/dev/null" _ "$OUT"
check "...and fails" test "$RC" != 0
check "...and the pod is deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
check "...and the check's output is in a local job log" grep -qF 'WEBGL_CHECK_FAIL: GPU_CONTEXT_LOST' "$(newest_log gfx-render)"

scenario; : > "$RP/requests.log"
gpu_env FAKE_SSH_WEBGL=post-lost
check "a failed check after the job turns GPU_OK into GPU_DEGRADED" \
  bash -c "printf '%s' \"\$1\" | grep -F 'GPU_DEGRADED: post-check failed' >/dev/null && ! printf '%s' \"\$1\" | grep 'GPU_OK' >/dev/null" _ "$OUT"
check "...exits non-zero" test "$RC" != 0
check "...and still downloads the job's results, for inspection" has "RESULT: $GFX/out/frame.png"

printf 't=1000 gpu=1 vram=900 vram_total=46068 cpu_usec=0 cpus=9 ram=2048 ram_total=51200\nDEGRADED t=1050 pattern=GPU process exited\nt=1100 gpu=2 vram=900 vram_total=46068 cpu_usec=9000000 cpus=9 ram=2048 ram_total=51200\n' > "$WORK/idle-watch.log"
scenario; gpu_env FAKE_SSH_WATCH="$WORK/idle-watch.log"
check "a sign in Chrome's log during the job turns the run into GPU_DEGRADED" has "GPU_DEGRADED: GPU process exited at"
check "a GPU idle while a graphics job ran is reported as degraded" has "GPU_DEGRADED: GPU idle (mean 1.5% over 100 s"
check "...and the run fails" test "$RC" != 0

scenario; : > "$RP/requests.log"
gpu_env FAKE_SSH_FAIL=render
check "a failing job's announced results are downloaded anyway" has "RESULT: $GFX/out/frame.png"
check "...and gpu still fails" test "$RC" != 0
check "...and says the results came anyway" has "downloaded anyway"
OUT="$(FAKE_HC_SCENARIO=running FAKE_SSH_FAIL=example PATH="$REPO/tests/fake-ssh:$PATH" cm job my-app example)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "job (Hetzner): a failing job's announced results are downloaded" has "RESULT: $APP/out/frame.png"
check "...and job still fails" test "$RC" != 0

echo "== gpu: the project's self-test and .cloudmule/files/"
printf '#!/usr/bin/env bash\necho checking frames\necho "CLOUDMULE_RESULT out/check.png"\n' > "$GFX/.cloudmule/jobs/gpu-selftest.sh"
printf 'GPU_SELFTEST=gpu-selftest\n' >> "$GFX/.cloudmule/config.sh"
scenario; : > "$FAKE_SSH_LOG"
OUT="$(PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render ep-01)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "with GPU_SELFTEST the run still ends GPU_OK when it passes" has "GPU_OK: render"
order="$(awk '/find \. /{if(!a)a=NR} /scripts\/gfx-gpu-selftest\.sh/{if(!b)b=NR} /scripts\/gfx-render\.sh/{if(!c)c=NR} END{print (a && b && c && a < b && b < c) ? "ok" : a" "b" "c}' "$FAKE_SSH_LOG")"
check "the self-test runs after the upload and before the job" test "$order" = ok
check "...with the job's arguments" bash -c "grep -F 'scripts/gfx-gpu-selftest.sh ep-01' '$FAKE_SSH_LOG' >/dev/null"
scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_env FAKE_SSH_FAIL=gpu-selftest
check "a failing self-test stops the run (GPU_SELFTEST_FAILED)" has "GPU_SELFTEST_FAILED"
check "...the real job never runs" bash -c "! grep 'scripts/gfx-render.sh' '$FAKE_SSH_LOG' >/dev/null"
check "...the self-test's results are downloaded" has "RESULT: $GFX/out/frame.png"
check "...and the pod is deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
cfg_drop "$GFX" GPU_SELFTEST; printf 'GPU_SELFTEST=no-such-check\n' >> "$GFX/.cloudmule/config.sh"
scenario; : > "$RP/requests.log"; gpu_env
check "a GPU_SELFTEST that names no job is refused before anything is created" \
  bash -c "printf '%s' \"\$1\" | grep GPU_SELFTEST_MISSING >/dev/null && [ \"\$(grep -c '^POST /v2/pods ' '$RP/requests.log')\" = 0 ]" _ "$OUT"
cfg_drop "$GFX" GPU_SELFTEST; rm -f "$GFX/.cloudmule/jobs/gpu-selftest.sh"

mkdir -p "$GFX/.cloudmule/files"; printf 'helper() { :; }\n' > "$GFX/.cloudmule/files/helpers.sh"
scenario; : > "$FAKE_SSH_LOG"; gpu_env
check ".cloudmule/files/ is uploaded to .cloudmule-files/" \
  bash -c "grep -F \"mkdir -p '/root/work/gfx/.cloudmule-files'\" '$FAKE_SSH_LOG' >/dev/null && grep -qx 'helpers.sh' '$CM_HOME/logs/.sync-push-gfx-files.txt'"
check "jobs find it in CLOUDMULE_FILES" grep -qF 'CLOUDMULE_FILES=/root/work/gfx/.cloudmule-files' "$FAKE_SSH_LOG"
check "the rest of .cloudmule/ is still never uploaded" bash -c "! grep '\.cloudmule/' '$CM_HOME/logs/.sync-push-gfx.txt' >/dev/null"
rm -rf "$GFX/.cloudmule/files"

echo "== gpu: a CUDA project (not graphics) gets the same measurements"
ML="$WORK/ml"; mkdir -p "$ML"; cm init "$ML" --name ml >/dev/null
sed -e 's/^# NEEDS_GPU=.*/NEEDS_GPU=cuda/' -e 's/^MODULES=.*/MODULES=""/' -e 's/^INSTALL_CMD=.*/INSTALL_CMD=""/' \
  "$ML/.cloudmule/config.sh" > "$WORK/c" && mv "$WORK/c" "$ML/.cloudmule/config.sh"
printf '#!/usr/bin/env bash\necho training\n' > "$ML/.cloudmule/jobs/train.sh"
scenario; : > "$FAKE_SSH_LOG"
OUT="$(FAKE_SSH_WATCH="$WORK/idle-watch.log" PATH="$REPO/tests/fake-ssh:$PATH" cm gpu ml --gpu "NVIDIA A40" --approved train)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "for cuda work a low GPU use is reported, not an error" bash -c "printf '%s' \"\$1\" | grep 'GPU_OK: train' >/dev/null && printf '%s' \"\$1\" | grep 'GPU_USE mean=2%' >/dev/null && ! printf '%s' \"\$1\" | grep GPU_DEGRADED >/dev/null" _ "$OUT"
check "cuda pods start from the CUDA image" grep -qF '"image": "runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04"' "$RP/requests.log"
check "cuda pods get no Chrome and no WebGL check" bash -c "! grep -e webgl-check -e chrome-libs -e chrome-gpu-flags '$FAKE_SSH_LOG' >/dev/null"
check "...but the watcher runs (without a Chrome log) and jobs get the pod's CPUs" \
  bash -c "grep -F 'gpu-watch.sh run /root/cloudmule/gpu-watch.log /root/cloudmule/jobs/ml-train.log - ' '$FAKE_SSH_LOG' >/dev/null && grep -F 'CLOUDMULE_CPUS=9' '$FAKE_SSH_LOG' >/dev/null"

echo "== gpu: a deadline before the time cap"
printf 'RUNPOD_MAX_MINUTES=0.5\n' >> "$CM_HOME/.env"
scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"; rm -f "$FAKE_SSH_STATE"/*
gpu_env CM_POLL_SECONDS=1 FAKE_SSH_SLOW=render
check "at the deadline the job is stopped (TERM to its process group)" grep -qF 'kill -TERM' "$FAKE_SSH_LOG"
check "...what it announced so far is downloaded" has "RESULT: $GFX/out/frame.png"
check "...the run ends GPU_TIME_CAP" has "GPU_TIME_CAP: stopped at"
check "...it fails" test "$RC" != 0
check "...and the pod is deleted" grep -q '^DELETE /v2/pods/fakepod1 ' "$RP/requests.log"
scenario; rm -f "$FAKE_SSH_STATE"/*
gpu_env CM_POLL_SECONDS=1 FAKE_SSH_NEAR=render
check "a run that ends near its time cap says so (NEAR_TIME_CAP)" has "NEAR_TIME_CAP:"
check "...and is still GPU_OK" has "GPU_OK: render"
sed '/^RUNPOD_MAX_MINUTES=0.5$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"

echo "== phase timings, one apt pass, catalog cache (spec 0005, step a)"
run gpus gfx
check "gpus shows only the fitting GPUs by default" bash -c "! printf '%s\n' \"\$1\" | grep ' no: ' >/dev/null && printf '%s\n' \"\$1\" | grep -E '^NVIDIA A40 .* fits' >/dev/null" _ "$OUT"
check "...says how many others there are and how to see them" has "and why: --all."
check "...with the vCPUs and RAM of each GPU's pods (catalog)" has "VCPU     RAM"
check "gpus writes the catalog cache" test -s "$CM_HOME/logs/runpod-catalog.json"
scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
gpu_env
check "gpu reads the price from a fresh catalog cache: no catalog request" bash -c "! grep '^GET /v2/catalog' '$RP/requests.log' >/dev/null"
check "the run prints how long each phase took (PHASES)" \
  bash -c "printf '%s\n' \"\$1\" | grep -E '^PHASES budget=[0-9]+ prep=[0-9]+ catalog=[0-9]+ create=[0-9]+ ssh=[0-9]+ modules=[0-9]+ mod\.apt=[0-9]+ .*webgl=[0-9]+ sync=[0-9]+ job=[0-9]+ pull=[0-9]+ postcheck=[0-9]+ delete=[0-9]+$' >/dev/null" _ "$OUT"
check "...also in the job's local log" grep -qE '^PHASES budget=' "$(newest_log gfx-render)"
check "...and in the pod's usage line (with the delete)" \
  bash -c "awk -F'\t' '\$13==\"runpod\" && \$17 ~ /^PHASES budget=.* delete=[0-9]+\$/' '$CM_HOME/logs/usage.tsv' | grep . >/dev/null"
run usage --phases
check "usage --phases shows each GPU run's phases and GPU use" bash -c "printf '%s\n' \"\$1\" | grep -E '^  PHASES budget=' >/dev/null && printf '%s\n' \"\$1\" | grep -E '^  GPU_USE mean=' >/dev/null" _ "$OUT"
check "a pod gets ONE apt pass with every module's packages, Chrome's included" \
  bash -c "[ \"\$(grep -c 'apt-pass.sh' '$FAKE_SSH_LOG')\" = 1 ] && grep 'apt-pass.sh' '$FAKE_SSH_LOG' | grep -F 'build-essential' | grep -F 'fontconfig' | grep -F 'google-chrome-stable' >/dev/null"
check "...each package once, even when two modules declare it, and 'a|b' kept as one word" \
  bash -c "grep -o 'apt-pass.sh[^;]*' '$FAKE_SSH_LOG' | head -1 | grep -o 'ca-certificates' | wc -l | grep -x ' *1' >/dev/null && grep 'apt-pass.sh' '$FAKE_SSH_LOG' | grep -F 'libatk1.0-0t64' | grep -F 'libatk1.0-0 ' >/dev/null"
check "...with the download-only modules (node) running beside it" grep -qF 'early-node-24.15.0.out' "$FAKE_SSH_LOG"
check "...and each module's own steps after it, without apt" bash -c "grep -F '/root/cloudmule/modules/gpu-graphics.sh' '$FAKE_SSH_LOG' | grep -v 'apt-pass' >/dev/null"
: > "$FAKE_SSH_LOG"
OUT="$(FAKE_HC_SCENARIO=running PATH="$REPO/tests/fake-ssh:$PATH" cm job my-app example)"; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "the shared server still installs module by module, each with its own apt packages" \
  bash -c "grep 'modules/base.sh' '$FAKE_SSH_LOG' | grep -F 'apt-pass.sh' | grep -F 'build-essential' >/dev/null && ! grep -F 'modules-apt' '$FAKE_SSH_LOG' >/dev/null"
"$PY" -I -c 'import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["SECURE"]["time"] = time.time() - 3600; json.dump(d, open(p, "w"))' \
  "$(winpath "$CM_HOME/logs/runpod-catalog.json")"
scenario; : > "$RP/requests.log"; gpu_env
check "with a stale catalog cache, gpu reads the catalog again" grep -q '^GET /v2/catalog' "$RP/requests.log"
scenario; : > "$RP/requests.log"
OUT="$(PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA RTX A4000" --approved render)"; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "a GPU the catalog gives no vCPUs or RAM for: the run's numbers stay in place (unknown, not shifted)" \
  bash -c "printf '%s\n' \"\$1\" | grep 'POD_CPUS=9 POD_RAM_GB=50 (jobs' >/dev/null && printf '%s\n' \"\$1\" | grep -E '^PHASES budget=[0-9]+ prep=[0-9]+ catalog=[0-9]+ create=[0-9]+ ' >/dev/null" _ "$OUT"
check "a named GPU the catalog lists as none available is still tried (RunPod decides)" \
  bash -c "grep -F '\"id\": \"NVIDIA RTX A4000\"' '$RP/requests.log' >/dev/null && printf '%s' \"\$1\" | grep 'GPU_OK: render' >/dev/null" _ "$OUT"
check "graphics pods start from the graphics image setting (RUNPOD_IMAGE_GRAPHICS_DEFAULT)" \
  bash -c "grep -F '\"image\": \"ghcr.io/brunochampion/cloudmule-gpu-graphics@sha256:' '$RP/requests.log' >/dev/null"
check "pods get Ubuntu's packages from the faster official mirror (RUNPOD_APT_MIRROR)" \
  bash -c "grep -F 'CM_APT_MIRROR=https://mirrors.edge.kernel.org/ubuntu' '$FAKE_SSH_LOG' >/dev/null"

echo "== lib/apt-pass.sh (fake apt-get and apt-cache)"
mkdir -p "$WORK/aptbin"
printf '#!/bin/sh\necho "apt-get $*" >> "%s"\n' "$WORK/apt.log" > "$WORK/aptbin/apt-get"
printf '#!/bin/sh\n[ "$2" = libx1 ] || [ "$2" = libz9t64 ]\n' > "$WORK/aptbin/apt-cache"
chmod +x "$WORK/aptbin/apt-get" "$WORK/aptbin/apt-cache"; : > "$WORK/apt.log"
PATH="$WORK/aptbin:$PATH" bash "$REPO/remote/modules/lib/apt-pass.sh" pkg-a 'libx1t64|libx1' 'libz9t64|libz9' pkg-b >/dev/null
check "apt-pass: one update, one install, the alternative this Ubuntu has" \
  bash -c "[ \"\$(grep -c 'apt-get update' '$WORK/apt.log')\" = 1 ] && grep -qx 'apt-get install -y -q --no-install-recommends pkg-a libx1 libz9t64 pkg-b' '$WORK/apt.log'"

echo "== gpu-logs (a running pod's job log, read-only)"
run gpu-logs
check "gpu-logs with no running pod says so" has "NO_RUNNING_POD"
check "...and fails" test "$RC" != 0
mkdir -p "$CM_HOME/logs/runpod"
printf '{"id": "live1", "run": "20261119000000-abc123", "project": "gfx", "target": "-", "job": "render", "created": %s, "cost": 0.59}\n' \
  "$(date +%s)" > "$CM_HOME/logs/runpod/live1.json"
: > "$CM_HOME/keys/pod-20261119000000-abc123"; echo "127.0.0.1 2222" > "$CM_HOME/keys/pod-20261119000000-abc123.addr"
: > "$FAKE_SSH_LOG"
OUT="$(PATH="$REPO/tests/fake-ssh:$PATH" cm gpu-logs abc123)"; RC=$?
check "gpu-logs shows the tail of the running job's log" has "rendering frame 120/1128"
check "...and what the watcher sees now (CPU against the pod's allotment)" \
  has "NOW GPU 25% · VRAM 4100/46068 MiB · CPU 80% of 9 vCPUs · RAM 10.1/50 GiB"
check "...reading the job's log on the pod" grep -qF 'gpu-watch.sh tail /root/cloudmule/jobs/gfx-render.log /root/cloudmule/gpu-watch.log' "$FAKE_SSH_LOG"
OUT="$(PATH="$REPO/tests/fake-ssh:$PATH" cm gpu-logs -f)"
check "gpu-logs -f follows this computer's newest pod" grep -qF 'gpu-watch.sh follow /root/cloudmule/jobs/gfx-render.log' "$FAKE_SSH_LOG"
rm -f "$CM_HOME/logs/runpod/live1.json" "$CM_HOME/keys/pod-20261119000000-abc123" "$CM_HOME/keys/pod-20261119000000-abc123.addr"

echo "== cloudmule-par (a job's tasks, N at a time)"
PD="$WORK/par"; mkdir -p "$PD/state"
# each task marks itself running, counts how many run, notes its private temp dir, waits 1 s; task 2 fails
for k in 1 2 3 4 5; do
  extra=""; [ "$k" = 2 ] && extra="; exit 3"
  printf 'mkdir "%s/state/run.$CLOUDMULE_TASK"; ls "%s/state" | grep -c "^run" >> "%s/conc"; echo "$CLOUDMULE_TASK_TMP" > "%s/tmp.$CLOUDMULE_TASK"; date +%%s > "%s/start.$CLOUDMULE_TASK"; sleep 1; rmdir "%s/state/run.$CLOUDMULE_TASK"; echo "task $CLOUDMULE_TASK says hi"%s\n' \
    "$PD" "$PD" "$PD" "$PD" "$PD" "$PD" "$extra"
done > "$PD/tasks.txt"
printf '# a comment\n\n' >> "$PD/tasks.txt"
OUT="$(bash "$REPO/remote/modules/lib/cloudmule-par.sh" --slots 2 --logs "$PD/logs" "$PD/tasks.txt" 2>&1)"; RC=$?
check "cloudmule-par never runs more than N tasks at once" test "$(sort -n "$PD/conc" | tail -1)" = 2
check "...and starts the next one as soon as one ends (5 one-second tasks, 2 slots: ~3 s)" \
  bash -c "w=\$(printf '%s\n' \"\$1\" | sed -n 's/.* wall=\([0-9]*\)\$/\1/p'); [ \"\$w\" -ge 2 ] && [ \"\$w\" -le 8 ]" _ "$OUT"
check "...one log per task" bash -c "grep -qx 'task 4 says hi' '$PD/logs/4.log' && [ \"\$(ls '$PD/logs' | wc -l | tr -d ' ')\" = 5 ]"
check "...one line per task with its exit code and time" bash -c "printf '%s\n' \"\$1\" | grep -E '^TASK 2 exit=3 secs=[0-9]+$' >/dev/null && printf '%s\n' \"\$1\" | grep -E '^TASK 5 exit=0 secs=[0-9]+$' >/dev/null" _ "$OUT"
check "...each task gets its own temp dir (CLOUDMULE_TASK_TMP)" bash -c "[ \"\$(cat '$PD'/tmp.* | sort -u | wc -l | tr -d ' ')\" = 5 ]"
check "...a failed task fails the run, while the others still finish" \
  bash -c "[ $RC != 0 ] && printf '%s\n' \"\$1\" | grep -E '^PAR slots=2 tasks=5 ok=4 failed=1 wall=[0-9]+$' >/dev/null" _ "$OUT"
OUT="$(bash "$REPO/remote/modules/lib/cloudmule-par.sh" --slots 0 "$PD/tasks.txt" 2>&1)"; RC=$?
check "cloudmule-par refuses a slot count that is not a whole number >= 1" bash -c "[ $RC = 2 ]"
check "the base module installs cloudmule-par (on every GPU pod)" grep -qF 'lib/cloudmule-par.sh' "$REPO/remote/modules/base.sh"

echo "== RunPod: pods already running, an optional cap, the launch lock, --max-minutes"
RUNNING_POD='{"id": "other7", "name": "cloudmule-short-form-render-long-f00ba4", "cost": 0.59, "gpu": {"id": "NVIDIA A40"}, "env": {"CLOUDMULE_MAX_MINUTES": "40"}, "runtime": {"uptimeInSeconds": 720}, "desiredStatus": "RUNNING"}'
scenario "{\"pods\": [$RUNNING_POD]}"; : > "$RP/requests.log"
gpu_env
check "gpu lists the cloudmule pods already running, from every session (RUNNING_PODS)" has "RUNNING_PODS: 1"
check "...one line per pod: project/job (its name), minutes up, run tag" has "cloudmule-short-form-render-long-f00ba4 (other7): NVIDIA A40, up 12 min, run tag f00ba4"
check "...and goes on: with no RUNPOD_MAX_PODS it never blocks" has "GPU_OK: render"
printf 'RUNPOD_MAX_PODS=1\n' >> "$CM_HOME/.env"
scenario "{\"pods\": [$RUNNING_POD]}"; : > "$RP/requests.log"
gpu_env
check "with RUNPOD_MAX_PODS=1 and one pod running, gpu is refused (TOO_MANY_PODS)" \
  bash -c "printf '%s\n' \"\$1\" | grep 'TOO_MANY_PODS' >/dev/null && printf '%s\n' \"\$1\" | grep 'cloudmule-short-form-render-long-f00ba4' >/dev/null" _ "$OUT"
check "...nothing is created" test "$(posts)" = 0
check "...and it fails" test "$RC" != 0
OUT="$(RUNPOD_MAX_PODS=9 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved render)"
check "RUNPOD_MAX_PODS cannot be raised from the environment" has "TOO_MANY_PODS"
scenario "{\"pods\": [$RUNNING_POD]}"; : > "$RP/requests.log"
( sleep 3; scenario ) & SWAP=$!
OUT="$(CM_WAIT_POD_POLL=1 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved --wait-for-pod 1 render)"; RC=$?
wait "$SWAP"
check "--wait-for-pod waits until a slot is free, then goes on" bash -c "printf '%s\n' \"\$1\" | grep 'waiting' >/dev/null && printf '%s\n' \"\$1\" | grep 'GPU_OK: render' >/dev/null" _ "$OUT"
scenario "{\"pods\": [$RUNNING_POD]}"
OUT="$(CM_WAIT_POD_POLL=1 PATH="$REPO/tests/fake-ssh:$PATH" cm gpu gfx --gpu "NVIDIA A40" --approved --wait-for-pod 0.05 render)"; RC=$?
check "...and gives up with TOO_MANY_PODS when the time runs out" bash -c "printf '%s\n' \"\$1\" | grep TOO_MANY_PODS >/dev/null && [ $RC != 0 ]" _ "$OUT"
sed '/^RUNPOD_MAX_PODS=1$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"

scenario; : > "$RP/requests.log"; : > "$FAKE_SSH_LOG"
run gpu gfx --gpu "NVIDIA A40" --max-minutes 60 --approved render
check "--max-minutes above RUNPOD_MAX_MINUTES is refused (never raised)" bash -c "printf '%s\n' \"\$1\" | grep 'ABOVE_TIME_CAP' >/dev/null && [ $RC != 0 ]" _ "$OUT"
check "...before anything is created" test "$(posts)" = 0
run gpu gfx --gpu "NVIDIA A40" --max-minutes 25 --dry-run render
check "--max-minutes sets the worst case reserved (0.59 USD/h x 25 min)" has "WOULD_CREATE: NVIDIA A40 SECURE 0.59 0.246"
gpu_run gfx --gpu "NVIDIA A40" --max-minutes 25 --approved render
check "...the pod's own cap in its env" grep -qF '"CLOUDMULE_MAX_MINUTES": "25"' "$RP/requests.log"
check "...the in-pod guard" has "Pod guard armed: the pod deletes itself in 2"
check "...and the deadline before it" bash -c "printf '%s\n' \"\$1\" | grep 'latest after 25 min' >/dev/null" _ "$OUT"
check "...and the run still works" has "GPU_OK: render"

# the launch lock: two runs whose worst cases together pass the daily cap (0.60 USD; each A40 pod reserves 0.393)
printf 'RUNPOD_MAX_USD_PER_DAY=0.60\n' >> "$CM_HOME/.env"
scenario; : > "$RP/requests.log"
( PATH="$REPO/tests/fake-ssh:$PATH" bash "$CM_HOME/bin/cloudmule" gpu gfx --gpu "NVIDIA A40" --approved render > "$WORK/lockA.out" 2>&1 ) &
A=$!
( PATH="$REPO/tests/fake-ssh:$PATH" bash "$CM_HOME/bin/cloudmule" gpu gfx --gpu "NVIDIA A40" --approved render > "$WORK/lockB.out" 2>&1 ) &
B=$!
wait "$A" "$B"
check "two launches at once that together pass the daily cap: exactly one is refused" \
  bash -c "[ \"\$(cat '$WORK/lockA.out' '$WORK/lockB.out' | grep -c 'DAILY_CAP_REACHED')\" = 1 ]"
sed '/^RUNPOD_MAX_USD_PER_DAY=0.60$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"
bash -c 'exit 0' & DEAD=$!; wait "$DEAD"   # a pid that just ended
mkdir -p "$CM_HOME/logs/runpod-launch.lock"; echo "$DEAD" > "$CM_HOME/logs/runpod-launch.lock/pid"
scenario; run gpu gfx --gpu "NVIDIA A40" --dry-run render
check "a launch lock left by a dead process is removed" bash -c "printf '%s\n' \"\$1\" | grep 'stale launch lock' >/dev/null && printf '%s\n' \"\$1\" | grep WOULD_CREATE >/dev/null" _ "$OUT"
sleep 30 & HOLDER=$!
mkdir -p "$CM_HOME/logs/runpod-launch.lock"; echo "$HOLDER" > "$CM_HOME/logs/runpod-launch.lock/pid"
OUT="$(CM_LAUNCH_LOCK_SECONDS=2 cm gpu gfx --gpu "NVIDIA A40" --dry-run render)"; RC=$?
kill "$HOLDER" 2>/dev/null; rm -rf "$CM_HOME/logs/runpod-launch.lock"
check "a launch lock held too long by a live process: LAUNCH_LOCK_TIMEOUT" bash -c "printf '%s\n' \"\$1\" | grep LAUNCH_LOCK_TIMEOUT >/dev/null && [ $RC != 0 ]" _ "$OUT"

echo "== the GPU watcher against fake cgroup files (v2, v1) and a fake nvidia-smi"
mkdir -p "$WORK/fakebin"; printf '#!/bin/sh\necho "37, 5000, 46068"\n' > "$WORK/fakebin/nvidia-smi"; chmod +x "$WORK/fakebin/nvidia-smi"
CG="$WORK/cg2"; mkdir -p "$CG"
printf 'cpu memory\n' > "$CG/cgroup.controllers"; echo '900000 100000' > "$CG/cpu.max"; echo 49999998976 > "$CG/memory.max"
printf 'usage_usec 5000000\nuser_usec 4000000\n' > "$CG/cpu.stat"; echo 10737418240 > "$CG/memory.current"
printf 'anon 9663676416\ninactive_file 1073741824\n' > "$CG/memory.stat"
watch_sh() { PATH="$WORK/fakebin:$PATH" CLOUDMULE_CGROUP_ROOT="$1" bash "$REPO/remote/gpu-watch.sh" "${@:2}"; }
OUT="$(watch_sh "$CG" alloc)"
check "cgroup v2: the pod's allotment from cpu.max and memory.max" has "POD_CPUS=9 POD_RAM_GB=50"
OUT="$(watch_sh "$CG" sample)"
check "cgroup v2: a sample has GPU, VRAM, the cgroup's CPU time and quota, RAM without the drop-able cache" \
  has "gpu=37 vram=5000 vram_total=46068 cpu_usec=5000000 cpus=9 ram=9216 ram_total=47684"
CG1="$WORK/cg1"; mkdir -p "$CG1/cpu" "$CG1/cpuacct" "$CG1/memory"
echo 600000 > "$CG1/cpu/cpu.cfs_quota_us"; echo 100000 > "$CG1/cpu/cpu.cfs_period_us"; echo 7000000000 > "$CG1/cpuacct/cpuacct.usage"
echo 30000000000 > "$CG1/memory/memory.limit_in_bytes"; echo 2147483648 > "$CG1/memory/memory.usage_in_bytes"
printf 'total_inactive_file 0\n' > "$CG1/memory/memory.stat"
OUT="$(watch_sh "$CG1" alloc)"; check "cgroup v1: the allotment from cfs_quota_us and limit_in_bytes" has "POD_CPUS=6 POD_RAM_GB=30"
OUT="$(watch_sh "$CG1" sample)"; check "cgroup v1: CPU time from cpuacct.usage" has "cpu_usec=7000000 cpus=6 ram=2048 ram_total=28610"
echo 'max 100000' > "$CG/cpu.max"; echo max > "$CG/memory.max"
OUT="$(watch_sh "$CG" alloc)"; check "no quota and no limit: empty values (gpu falls back to the catalog)" has "POD_CPUS= POD_RAM_GB="
OUT="$(watch_sh "$CG" sample 9)"; check "...and the CPU use is then measured against the catalog's vCPUs" has "cpus=9"
printf 'working\nEXIT 0\n' > "$WORK/job.log"; printf 'THREE.WebGLRenderer: Context Lost.\n' > "$WORK/chrome.log"; : > "$WORK/w.log"
watch_sh "$CG" run "$WORK/w.log" "$WORK/job.log" "$WORK/chrome.log" 9 20 1
check "the watcher stops when the job's log ends" test "$(grep -c '^t=' "$WORK/w.log")" = 1
check "...and notes a sign in Chrome's log" grep -qF 'DEGRADED t=' "$WORK/w.log"
printf 't=100 gpu=10 vram=1 vram_total=2 cpu_usec=0 cpus=9 ram=1 ram_total=2\nt=102 gpu=10 vram=1 vram_total=2 cpu_usec=9000000 cpus=9 ram=1 ram_total=2\n' > "$WORK/w2.log"
OUT="$("$PY" -I "$(winpath "$CM_HOME/bin/tools.py")" gpu-summary "$(winpath "$WORK/w2.log")" --needs cuda 2>&1)"
check "CPU use is against the pod's allotment, not the host's threads (9 CPU-s in 2 s on 9 vCPUs = 50%)" has "CPU mean=50% of 9 vCPUs"
check "a cuda run never gets GPU_DEGRADED from the watcher" hasnt "GPU_DEGRADED"
cat > "$WORK/verdicts.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("check", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
nv = "ANGLE (NVIDIA Corporation, NVIDIA A40/PCIe/SSE2, OpenGL ES 3.2)"
for name, r, err, problem in [
    ("ok", {"renderer_before": nv, "renderer_after": nv, "lost": 0, "texel_ok": 1}, "", ""),
    ("software", {"renderer_before": "ANGLE (Google, SwiftShader Device)", "renderer_after": "x", "lost": 0, "texel_ok": 1}, "", ""),
    ("lost-at-once", {"renderer_before": "null", "renderer_after": "null", "lost": 1, "texel_ok": 0}, "", ""),
    ("restored", {"renderer_before": nv, "renderer_after": nv, "lost": 0, "texel_ok": 0}, "", ""),
    ("gpu-crash", None, "[1:2:ERROR] GPU process exited unexpectedly", "no answer"),
    ("no-chrome", None, "", "could not start google-chrome")]:
    print(name, m.verdict(r, [], err, problem)[0])
PY
OUT="$("$PY" -I "$(winpath "$WORK/verdicts.py")" "$(winpath "$CM_HOME/remote/modules/lib/webgl-check.py")" 2>&1)"
check "the WebGL check's verdicts: NVIDIA ok; software, no Chrome -> GPU_NOT_USED (3); loss, wrong texel, GPU crash -> GPU_CONTEXT_LOST (4)" \
  bash -c "[ \"\$(printf '%s' \"\$1\" | tr -d '\r' | tr '\n' ' ')\" = 'ok 0 software 3 lost-at-once 4 restored 4 gpu-crash 4 no-chrome 3' ]" _ "$OUT"

echo "== the prebuilt graphics image (images/gpu-graphics)"
IMG="$(sed -n 's/^RUNPOD_IMAGE_GRAPHICS_DEFAULT="\([^"]*\)".*/\1/p' "$REPO/bin/lib.sh")"
IMG_SRC="$(sed -n 's/^RUNPOD_IMAGE_GRAPHICS_SOURCE="\{0,1\}\([0-9a-f]*\).*/\1/p' "$REPO/bin/lib.sh")"
SRC_NOW="$("$PY" -I "$(winpath "$REPO/images/gpu-graphics/modules-hash.py")" "$(winpath "$REPO")")"
case "$IMG" in
  ghcr.io/*@sha256:*)
    check "the prebuilt image was built from today's modules (else rebuild it: .github/workflows/gpu-image.yml)" \
      test "$IMG_SRC" = "$SRC_NOW" ;;
  *) skip "no prebuilt graphics image recorded yet (RUNPOD_IMAGE_GRAPHICS_DEFAULT is not a ghcr.io digest)" ;;
esac
check "the image's module list is the one a graphics pod installs (base chrome-libs gpu-graphics node ffmpeg)" \
  grep -qF 'install-modules.sh base chrome-libs gpu-graphics "node@${NODE_VERSION}" ffmpeg' "$REPO/images/gpu-graphics/Dockerfile"
check "the image's source hash can be computed (16 hex characters)" \
  bash -c "printf '%s' '$SRC_NOW' | grep -E '^[0-9a-f]{16}$' >/dev/null"

echo "== the monthly cap (RUNPOD_MAX_USD_PER_MONTH)"
printf 'RUNPOD_MAX_USD_PER_MONTH=15\nRUNPOD_MAX_USD_PER_DAY=100\n' >> "$CM_HOME/.env"
cp "$CM_HOME/logs/usage.tsv" "$WORK/usage-before-month.tsv"
LASTMONTH="$("$PY" -c 'import datetime as d; t = d.date.today().replace(day=1) - d.timedelta(days=1); print(t.strftime("%Y-%m-%dT10:00"))')"
awk -F'\t' '$13 != "runpod"' "$CM_HOME/logs/usage.tsv" > "$WORK/u" && mv "$WORK/u" "$CM_HOME/logs/usage.tsv"
{ printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t12.5000\n' "$NOW"
  printf '%s\tother\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t100.0000\n' "$LASTMONTH"; } >> "$CM_HOME/logs/usage.tsv"
scenario; : > "$RP/requests.log"
run gpus gfx
check "gpus shows this month's spend against the monthly cap (last month's not counted)" has "This month's GPU spend: 12.50 of 15 USD"
check "at 80% of the monthly cap it warns (MONTHLY_CAP_NEAR)" has "MONTHLY_CAP_NEAR: 12.50 of 15 USD"
run gpu gfx --gpu "NVIDIA A40" --dry-run render
check "gpu warns near the monthly cap too, and a pod that fits is still possible" \
  bash -c "printf '%s' \"\$1\" | grep MONTHLY_CAP_NEAR >/dev/null && printf '%s' \"\$1\" | grep 'WOULD_CREATE: NVIDIA A40' >/dev/null" _ "$OUT"
printf '%s\tgfx\t-\trender\tNVIDIA A40\t600\tn/a\tn/a\tn/a\tn/a\t0\tn/a\trunpod\t11000\t2.3000\n' "$NOW" >> "$CM_HOME/logs/usage.tsv"
run gpu gfx --gpu "NVIDIA A40" --approved render
check "a pod whose worst case passes this month's cap is refused (MONTHLY_CAP_REACHED)" has "MONTHLY_CAP_REACHED"
OUT="$(RUNPOD_MAX_USD_PER_MONTH=500 cm gpu gfx --gpu "NVIDIA A40" --approved render)"; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "the monthly cap cannot be raised from the environment" has "MONTHLY_CAP_REACHED"
check "...and nothing was created" test "$(posts)" = 0
run usage --month
check "usage --month lists this month's GPU spend by project, without last month's" \
  bash -c "printf '%s\n' \"\$1\" | grep -E '^gfx +2 +14\.80 USD' >/dev/null && ! printf '%s\n' \"\$1\" | grep '^other' >/dev/null" _ "$OUT"
run usage
check "usage shows the month's GPU spend next to the day's" has "this month,"
cp "$WORK/usage-before-month.tsv" "$CM_HOME/logs/usage.tsv"
sed -e '/^RUNPOD_MAX_USD_PER_MONTH=15$/d' -e '/^RUNPOD_MAX_USD_PER_DAY=100$/d' "$CM_HOME/.env" > "$WORK/env" && mv "$WORK/env" "$CM_HOME/.env"

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
  {"id": "other1", "name": "my-notebook", "cost": 0.69, "gpu": {"id": "NVIDIA L4"}, "runtime": {"uptimeInSeconds": 7200}},
  {"id": "long1", "name": "cloudmule-big-render-abc123", "cost": 0.59, "gpu": {"id": "NVIDIA A40"}, "env": {"CLOUDMULE_MAX_MINUTES": "180"}, "runtime": {"uptimeInSeconds": 7200}}]}'
: > "$RP/requests.log"
OUT="$(FAKE_HC_SCENARIO=empty cm status)"; RC=$?; printf '%s\n' "$OUT" >> "$ALL_OUT"
check "status lists the RunPod pods" has "== RunPod GPU pods"
check "status lists a running cloudmule pod with its GPU, price and age" has "cloudmule-gfx-render (young1): NVIDIA A40, 0.59 USD/h, up 5 min"
check "status deletes a cloudmule pod past its time cap and says so" has "ORPHAN_DELETED: cloudmule-old-render (old1)"
check "...through the API" grep -q '^DELETE /v2/pods/old1 ' "$RP/requests.log"
check "status warns about a pod that is not cloudmule's, without touching it" has "WARNING: my-notebook (other1) is not cloudmule's"
check "...and never deletes it" bash -c "! grep '^DELETE /v2/pods/other1 ' '$RP/requests.log' >/dev/null"
check "a pod created with a longer time cap (another computer's .env) is not deleted before its own cap" \
  bash -c "! grep '^DELETE /v2/pods/long1 ' '$RP/requests.log' >/dev/null"
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
