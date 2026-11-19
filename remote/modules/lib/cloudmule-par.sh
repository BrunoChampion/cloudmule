#!/usr/bin/env bash
# cloudmule-par — runs a job's independent tasks N at a time on one machine (docs/specs/0005: tasks and slots).
# Installed on every GPU pod by the base module (/usr/local/bin/cloudmule-par); on the shared Hetzner server when its
# base module is (re)installed. Generic: it knows nothing about Chrome, video or ML.
#
#   cloudmule-par --slots N [--logs DIR] TASKS_FILE
#
# TASKS_FILE has one shell command per line (one task each; empty lines and lines starting with # are skipped).
# At most N tasks run at once; the next one starts as soon as one ends, so many small tasks even out.
# Each task k (1, 2, …, in file order) runs in bash with:
#   - its own log, DIR/<k>.log (DIR: --logs, else $CLOUDMULE_PAR_LOGS, else ./cloudmule-par-logs);
#   - CLOUDMULE_TASK=<k>, CLOUDMULE_TASK_TMP=<a private temp dir> (e.g. Chrome's --user-data-dir) and
#     CLOUDMULE_PAR_LOGS=<DIR> in its environment.
# At the end: one line per task, "TASK <k> exit=<code> secs=<seconds>", then
# "PAR slots=N tasks=T ok=O failed=F wall=<seconds>". Exit code 1 if any task failed: the others still run to the end,
# so their results are kept. Slots: use the pod's CPUs (CLOUDMULE_CPUS) and the job's measured use (GPU_USE), never
# nproc; see the cloudmule skill ("many tasks").
set -u

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
slots=""; logs="${CLOUDMULE_PAR_LOGS:-cloudmule-par-logs}"; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slots) slots="${2:-}"; shift 2 ;;
    --logs) logs="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "cloudmule-par: unknown option $1" >&2; exit 2 ;;
    *) file="$1"; shift ;;
  esac
done
case "$slots" in ''|*[!0-9]*|0) echo "cloudmule-par: --slots needs a whole number >= 1" >&2; exit 2 ;; esac
[ -n "$file" ] && [ -r "$file" ] || { echo "cloudmule-par: no tasks file (usage: cloudmule-par --slots N [--logs DIR] TASKS_FILE)" >&2; exit 2; }
[ -n "$logs" ] || { echo "cloudmule-par: --logs needs a folder" >&2; exit 2; }
mkdir -p "$logs" && logs="$(cd "$logs" && pwd)" || { echo "cloudmule-par: cannot use $logs for the logs" >&2; exit 2; }

total=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  total=$((total + 1)); cmd[$total]="$line"
done < "$file"
[ "$total" -gt 0 ] || { echo "cloudmule-par: $file has no tasks"; echo "PAR slots=$slots tasks=0 ok=0 failed=0 wall=0"; exit 0; }

root="$(mktemp -d "${TMPDIR:-/tmp}/cloudmule-par.XXXXXX")" || exit 2
trap 'rm -rf "$root"' EXIT
trap 'kill $(jobs -p) 2>/dev/null; exit 143' INT TERM   # stopped: the tasks stop too
t0=$(date +%s); next=1; active=0; ok=0; failed=0
running=" "   # the task numbers running now

start_task() {   # start_task <k>
  local k="$1"
  mkdir -p "$root/$k"
  ( export CLOUDMULE_TASK="$k" CLOUDMULE_TASK_TMP="$root/$k" CLOUDMULE_PAR_LOGS="$logs"
    exec bash -c "${cmd[$k]}" ) > "$logs/$k.log" 2>&1 < /dev/null &
  pid[$k]=$!; began[$k]=$(date +%s); running="$running$k "; active=$((active + 1))
  echo "cloudmule-par: task $k started ($active of $slots slots): ${cmd[$k]:0:100}"
}

while [ "$next" -le "$total" ] || [ "$active" -gt 0 ]; do
  while [ "$active" -lt "$slots" ] && [ "$next" -le "$total" ]; do start_task "$next"; next=$((next + 1)); done
  alive=" $(jobs -rp | tr '\n' ' ')"
  for k in $running; do
    case "$alive" in *" ${pid[$k]} "*) continue ;; esac
    wait "${pid[$k]}"; rc=$?
    code[$k]=$rc; secs[$k]=$(( $(date +%s) - began[$k] ))
    running="${running/ $k / }"; active=$((active - 1))
    if [ "$rc" = 0 ]; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
    echo "cloudmule-par: task $k ended (exit $rc, ${secs[$k]} s); log: $logs/$k.log"
  done
  [ "$active" -lt "$slots" ] && [ "$next" -le "$total" ] && continue
  [ "$active" -gt 0 ] && sleep 0.2
done

k=1
while [ "$k" -le "$total" ]; do echo "TASK $k exit=${code[$k]} secs=${secs[$k]}"; k=$((k + 1)); done
echo "PAR slots=$slots tasks=$total ok=$ok failed=$failed wall=$(( $(date +%s) - t0 ))"
[ "$failed" = 0 ]
