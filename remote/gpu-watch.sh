#!/usr/bin/env bash
# GPU watcher. Runs INSIDE a RunPod GPU pod (graphics and cuda), uploaded by `cloudmule gpu` with the pod guard.
#
#   gpu-watch.sh alloc
#       the pod's own allotment, from its cgroup: "POD_CPUS=<n> POD_RAM_GB=<n>" (empty value: no limit found)
#   gpu-watch.sh sample [<fallback cpus>]
#       one sample line (key=value): t gpu vram vram_total cpu_usec cpus ram ram_total
#   gpu-watch.sh tail|follow <job log> <watch log>
#       for `cloudmule gpu-logs`: the job log's last lines and the watcher's last samples ("WATCH <sample>" lines, then
#       "WATCH_END"); follow repeats it every 10 s with the new lines, until the job's EXIT line
#   gpu-watch.sh run <out> <job log> <chrome log|-> <fallback cpus> <max seconds> [interval]
#       appends one sample every <interval> s (2) to <out> until the job's log ends with its "EXIT" line (or after
#       <max seconds>). With a Chrome log, also appends "DEGRADED t=<epoch> pattern=<text>" the first time it shows a
#       sign that Chrome left the GPU. It never stops or kills the job: `cloudmule gpu` judges the run at the end.
#
# CPU and RAM come from the container's cgroup (v2, else v1), never from /proc/stat, nproc, /proc/cpuinfo or
# /proc/meminfo: inside a RunPod container those show the whole host (96 threads on an A40 host whose pod is
# allotted 9 vCPUs). CLOUDMULE_CGROUP_ROOT replaces /sys/fs/cgroup (tests).
set -u
CG="${CLOUDMULE_CGROUP_ROOT:-/sys/fs/cgroup}"
PATTERNS='GPU process exited|GPU process crashed|SwiftShader|Context Lost|context lost'

first_file() { local f; for f in "$@"; do [ -r "$f" ] && { echo "$f"; return 0; }; done; return 1; }
v2() { [ -r "$CG/cgroup.controllers" ] || [ -r "$CG/cpu.max" ] || [ -r "$CG/memory.max" ]; }

# quota_cpus: the CPU quota as a number of CPUs ("9", "4.5"), empty when there is none
quota_cpus() {
  local q p f
  if v2 && [ -r "$CG/cpu.max" ]; then
    read -r q p < "$CG/cpu.max"
  else
    f="$(first_file "$CG/cpu/cpu.cfs_quota_us" "$CG/cpu,cpuacct/cpu.cfs_quota_us")" || return 0
    q="$(cat "$f")"; p="$(cat "${f%quota_us}period_us" 2>/dev/null)"
  fi
  case "$q" in ""|max|-1) return 0 ;; esac
  awk -v q="$q" -v p="${p:-100000}" 'BEGIN { if (p > 0 && q > 0) printf "%g", q / p }'
}

# ram_limit: the memory limit in bytes, empty when there is none (v1 reports a huge number then)
ram_limit() {
  local v f
  if v2 && [ -r "$CG/memory.max" ]; then v="$(cat "$CG/memory.max")"
  else f="$(first_file "$CG/memory/memory.limit_in_bytes")" || return 0; v="$(cat "$f")"; fi
  case "$v" in ""|max) return 0 ;; esac
  awk -v v="$v" 'BEGIN { if (v > 0 && v < 2^60) printf "%.0f", v }'
}

# cpu_usec: CPU time used by every process of the container so far, in microseconds
cpu_usec() {
  local f
  if v2 && [ -r "$CG/cpu.stat" ]; then awk '/^usage_usec/ { print $2 }' "$CG/cpu.stat"; return; fi
  f="$(first_file "$CG/cpuacct/cpuacct.usage" "$CG/cpu,cpuacct/cpuacct.usage")" || return 0
  awk '{ printf "%.0f", $1 / 1000 }' "$f"
}

# ram_used: the container's memory in use, in bytes, without the file cache it can drop (inactive_file)
ram_used() {
  local cur stat
  if v2 && [ -r "$CG/memory.current" ]; then cur="$(cat "$CG/memory.current")"; stat="$CG/memory.stat"
  else cur="$(cat "$CG/memory/memory.usage_in_bytes" 2>/dev/null)"; stat="$CG/memory/memory.stat"; fi
  [ -n "$cur" ] || return 0
  [ -r "$stat" ] || { echo "$cur"; return 0; }
  awk -v cur="$cur" '$1 == "inactive_file" || $1 == "total_inactive_file" { i = $2 } END { printf "%.0f", cur - i }' "$stat"
}

mib() { [ -n "$1" ] && awk -v b="$1" 'BEGIN { printf "%.0f", b / 1048576 }'; }

alloc() {
  local c r
  c="$(quota_cpus)"; r="$(ram_limit)"
  [ -z "$c" ] || c="$(awk -v c="$c" 'BEGIN { n = int(c); print (n < 1 ? 1 : n) }')"
  # decimal GB, rounded, like RunPod's catalog (minRam): 49999998976 bytes -> 50
  [ -z "$r" ] || r="$(awk -v r="$r" 'BEGIN { printf "%d", r / 1e9 + 0.5 }')"
  echo "POD_CPUS=$c POD_RAM_GB=$r"
}

sample() {
  local fallback="${1:-}" g cpus ram_total
  g="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
       | head -1 | tr -d ' ')"
  cpus="$(quota_cpus)"; [ -n "$cpus" ] || cpus="$fallback"
  ram_total="$(mib "$(ram_limit)")"
  echo "t=$(date +%s) gpu=$(echo "$g" | cut -d, -f1) vram=$(echo "$g" | cut -s -d, -f2) vram_total=$(echo "$g" | cut -s -d, -f3)" \
       "cpu_usec=$(cpu_usec) cpus=$cpus ram=$(mib "$(ram_used)") ram_total=$ram_total"
}

run() {
  local out="$1" joblog="$2" chrome="$3" fallback="$4" max="$5" every="${6:-2}" t0 seen=0 hit
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$max" ]; do
    sample "$fallback" >> "$out"
    if [ "$chrome" != - ] && [ "$seen" = 0 ] && [ -r "$chrome" ]; then
      hit="$(grep -m1 -oE "$PATTERNS" "$chrome" 2>/dev/null || true)"
      [ -z "$hit" ] || { echo "DEGRADED t=$(date +%s) pattern=$hit" >> "$out"; seen=1; }
    fi
    if [ -r "$joblog" ] && tail -n 1 "$joblog" 2>/dev/null | grep -E '^EXIT [0-9]+' >/dev/null; then break; fi
    sleep "$every"
  done
}

watched() { tail -n 6 "$1" 2>/dev/null | grep '^t=' | sed 's/^/WATCH /'; echo WATCH_END; }

follow() {
  local log="$1" w="$2" n=0 total once="${3:-}"
  while :; do
    if [ -r "$log" ]; then
      total=$(wc -l < "$log" | tr -d ' ')
      [ "$total" -ge "$n" ] || n=0   # the log was started again
      if [ "$n" = 0 ]; then tail -n 40 "$log"; elif [ "$total" -gt "$n" ]; then sed -n "$((n + 1)),${total}p" "$log"; fi
      n=$total
    else
      echo "(no job log yet: $log)"
    fi
    watched "$w"
    [ -z "$once" ] || break
    tail -n 1 "$log" 2>/dev/null | grep -E '^EXIT ' >/dev/null && break
    sleep 10
  done
}

case "${1:-}" in
  alloc) alloc ;;
  tail) follow "$2" "$3" once ;;
  follow) follow "$2" "$3" ;;
  sample) sample "${2:-}" ;;
  run) shift; run "$@" ;;
  *) echo "usage: gpu-watch.sh alloc | sample [cpus] | run <out> <job log> <chrome log|-> <cpus> <max s> [interval]" >&2; exit 2 ;;
esac
