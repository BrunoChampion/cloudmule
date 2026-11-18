#!/usr/bin/env bash
# Pod guard. Runs INSIDE a RunPod GPU pod, started by `cloudmule gpu` right after SSH answers, detached:
# deletes the pod after <seconds> even if the computer that created it crashed or is off.
#
# usage: pod-guard.sh <seconds>
#
# It uses the pod's own credentials, never the user's key: RunPod puts the pod's id (RUNPOD_POD_ID) and a
# pod-scoped API key (RUNPOD_API_KEY) in the environment of the pod's first process, and its images ship
# runpodctl. If neither way works, it stops the container as a last resort: a stopped pod no longer bills for the
# GPU but still bills for its disk until it is deleted (cloudmule's local watchdog and orphan checks do that).
set -u
sleep "${1:?seconds}"
pod_env() { tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$1=//p" | head -1; }
ID="${RUNPOD_POD_ID:-$(pod_env RUNPOD_POD_ID)}"
KEY="${RUNPOD_API_KEY:-$(pod_env RUNPOD_API_KEY)}"
echo "$(date -u +%FT%TZ) time cap reached: deleting pod ${ID:-?}"
if [ -n "$ID" ] && command -v runpodctl >/dev/null 2>&1; then
  RUNPOD_API_KEY="$KEY" runpodctl remove pod "$ID" && exit 0
fi
if [ -n "$ID" ] && [ -n "$KEY" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
    | curl -fsS -X DELETE -K - "https://api.runpod.io/v2/pods/$ID" && exit 0
fi
echo "could not delete the pod through RunPod: stopping the container" >&2
kill -TERM 1
