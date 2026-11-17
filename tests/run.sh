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
run() { OUT="$(cm "$@")"; RC=$?; }   # sets OUT and RC

echo "== a clone"
check "a clone has no .env, keys/, logs/ or registry/" \
  bash -c "[ ! -e '$CM_HOME/.env' ] && [ ! -e '$CM_HOME/keys' ] && [ ! -e '$CM_HOME/logs' ] && [ ! -e '$CM_HOME/registry' ]"
run help;     check "help works without a token" has "cloudmule servers"
run status;   check "a Hetzner command without a token asks for it" has "HCLOUD_TOKEN is missing"
run projects; check "no projects at first" has "no projects yet"
run usage;    check "usage works without a token, and says nothing is recorded yet" has "No job usage recorded yet"

printf 'HCLOUD_TOKEN=fake-token-for-tests\nSERVER_TYPES="cx53 cpx62"\nLOCATIONS="nbg1 fsn1 hel1"\n' > "$CM_HOME/.env"

echo "== setup"
run setup
check "setup succeeds" has "SETUP_OK"
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
check "cpx62 fits, with no warning (it keeps the disk floor)" row_plain_fit cpx62
check "a bigger disk says it raises the disk floor and what is lost" row_has ccx63 "fits; raises disk floor 640 -> 960 GB (1 type lost)"
check "cx23 does not fit, with the reasons" has "no: ram < 8 GB; below disk floor 640 GB (or --fresh)"
check "arm types are marked as the wrong architecture" has "arch arm (project needs x86)"
check "unavailable types are marked" has "unavailable"
check "it recommends the cheapest fitting type" has "RECOMMENDED: cpx62 hel1 0.2083"
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

echo "== servers (the server is running: no choice now)"
OUT="$(FAKE_HC_SCENARIO=running cm servers videos)"
check "a running server: no guide" hasnt "How to choose"
check "a running server: the next disk floor is its own disk" has "Disk floor next time: 80 GB"
check "a running server: no escape advice (start would join it)" hasnt "Cheaper with --fresh"

echo "== start --dry-run"
run start videos --dry-run
check "without --type it takes the first fitting preference" has "WOULD_CREATE: cpx62 hel1 1000001 0.2083"
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
run start videos --dry-run
check "the project's SERVER_TYPES overrides .env's" has "WOULD_CREATE: ccx63 hel1"
OUT="$(SERVER_TYPES="ccx43 cpx62" cm start my-app --fresh --dry-run)"
check "a setting in the environment wins over .env" has "WOULD_CREATE: ccx43 hel1"
OUT="$(FAKE_HC_SCENARIO=available cm start my-app --fresh --dry-run)"
check "when everything is available, the first preference that fits is used" has "WOULD_CREATE: cx53"
OUT="$(FAKE_HC_SCENARIO=running cm start videos --dry-run)"
check "a running server is joined, with its type" has "already running (203.0.113.10, cpx22"
check "a running server below the project's needs is reported" has "SERVER_BELOW_REQUIREMENTS: ram < 8 GB"
check "joining needs no choice" has "WOULD_JOIN: cloudmule"
OUT="$(FAKE_HC_SCENARIO=running cm start videos --fresh --dry-run)"
check "--fresh is refused while the server is running" has "--fresh needs the server to be off"
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

echo "== end --keep (the server cannot be reached: the save must still happen through the API)"
: > "$WORK/before.log"; cp "$FAKE_HC_LOG" "$WORK/before.log"
OUT="$(FAKE_HC_SCENARIO=running cm end videos --keep)"
NEW="$(tail -n +"$(( $(wc -l < "$WORK/before.log") + 1 ))" "$FAKE_HC_LOG")"
calls() { printf '%s\n' "$NEW" | grep -E "$1" >/dev/null; }
check "end --keep snapshots the server with cloudmule's labels" \
  calls '^server create-image --type snapshot .*--label managed-by=cloudmule --label role=workspace --label scope=shared cloudmule$'
check "end --keep keeps only the newest workspace snapshot" calls '^image delete 1000001$'
check "end --keep does not delete the newest snapshot" bash -c "! printf '%s\n' \"\$1\" | grep -q '^image delete 1000002'" _ "$NEW"
check "end --keep deletes the server" calls '^server delete cloudmule$'
check "no test ever asked Hetzner to create a server" bash -c "! grep -q '^server create ' '$FAKE_HC_LOG'"
check "every Hetzner call was one the fake knows" bash -c "! grep -q '^UNHANDLED' '$FAKE_HC_LOG'"

echo
echo "RESULT: $PASSES passed, $FAILS failed, $SKIPS skipped"
[ "$FAILS" = 0 ]
