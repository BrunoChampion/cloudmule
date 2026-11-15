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

echo "== servers (saved workspace from a 640 GB disk)"
run servers videos
check "servers succeeds" test "$RC" = 0
check "it shows the workspace's disk limit" has "restores only on a disk >= 640 GB"
check "it shows the project's needs and their source" has "RAM >= 8 GB (config)"
check "it derives the architecture from the modules" has "CPU architecture: x86 (from its MODULES)"
check "cpx62 fits" bash -c "printf '%s\n' \"\$1\" | grep -E '^cpx62 .* fits$' >/dev/null" _ "$OUT"
check "cx23 does not fit, with the reasons" has "no: ram < 8 GB; workspace needs disk >= 640 GB (or --fresh)"
check "arm types are marked as the wrong architecture" has "arch arm (project needs x86)"
check "unavailable types are marked" has "unavailable"
check "it recommends the cheapest fitting type" has "RECOMMENDED: cpx62 hel1 0.2083"
run servers videos --fresh
check "servers --fresh ignores the workspace" has "Saved workspace: ignored (--fresh)"
check "servers --fresh recommends a smaller server" has "RECOMMENDED: cpx32 hel1"
run servers
check "servers without a project applies no project needs" bash -c "! printf '%s' \"\$1\" | grep -q 'Project ' " _ "$OUT"
check "servers without a project still recommends" has "RECOMMENDED: cpx62"
OUT="$(FAKE_HC_SCENARIO=empty cm servers videos)"
check "with no snapshot, it warns that the first disk limits later restores" has "Saved workspace: none yet"

echo "== start --dry-run"
run start videos --dry-run
check "without --type it takes the first fitting preference" has "WOULD_CREATE: cpx62 hel1 1000001 0.2083"
run start videos --type cx23 --dry-run
check "a type that cannot restore the workspace is refused" bash -c "[ $RC != 0 ]"
check "the refusal explains why" has "NO_FITTING_SERVER: cx23: ram < 8 GB; workspace needs disk >= 640 GB (or --fresh)"
run start videos --type cpx42 --fresh --dry-run
check "--fresh allows a smaller type, from plain Ubuntu" has "WOULD_CREATE: cpx42 hel1 ubuntu-24.04"
run start videos --type cpx62 --location nbg1 --dry-run
check "--location picks the location" has "WOULD_CREATE: cpx62 nbg1 1000001"
run start videos --type cpx62 --location mars1 --dry-run
check "an unknown location is refused" has "is not in LOCATIONS"
printf 'SERVER_TYPES="ccx63 cpx62"\n' >> "$VID/.cloudmule/config.sh"
run start videos --dry-run
check "the project's SERVER_TYPES overrides .env's" has "WOULD_CREATE: ccx63 hel1"
OUT="$(FAKE_HC_SCENARIO=available cm start my-app --fresh --dry-run)"
check "when everything is available, the first preference that fits is used" has "WOULD_CREATE: cx53"
OUT="$(FAKE_HC_SCENARIO=running cm start videos --dry-run)"
check "a running server is joined, with its type" has "already running (203.0.113.10, cpx22"
check "a running server below the project's needs is reported" has "SERVER_BELOW_REQUIREMENTS: ram < 8 GB"
check "joining needs no choice" has "WOULD_JOIN: cloudmule"
OUT="$(FAKE_HC_SCENARIO=running cm start videos --fresh --dry-run)"
check "--fresh is refused while the server is running" has "--fresh needs the server to be off"
check "no test ever asked Hetzner to create a server" bash -c "! grep -q '^server create' '$FAKE_HC_LOG'"
check "every Hetzner call was one the fake knows" bash -c "! grep -q '^UNHANDLED' '$FAKE_HC_LOG'"

echo
echo "RESULT: $PASSES passed, $FAILS failed, $SKIPS skipped"
[ "$FAILS" = 0 ]
