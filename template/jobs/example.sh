# Example job: `cloudmule job <project> example`. Runs ON the server, in REMOTE_DIR, with the job's arguments in
# "$@" and $TARGET set. Rename it or write one script per heavy task (test.sh, build.sh, render.sh…).
# Rules:
#   - Exit non-zero on failure (`set -euo pipefail`); the full log is copied to cloudmule/logs/.
#   - Print "CLOUDMULE_RESULT <path relative to the project>" for every file or folder to bring back to this
#     computer; cloudmule downloads it to the same relative path in LOCAL_DIR (paths without spaces).
#   - Long-running servers (a dev server to look at through `cloudmule tunnel`) must detach themselves
#     (setsid … &) and print how to stop them; the job itself should end.
set -euo pipefail
echo "Running on $(hostname) with $(nproc) CPUs, target: ${TARGET:-none}, args: $*"
mkdir -p .cloudmule-out
node --version > .cloudmule-out/node-version.txt
echo "CLOUDMULE_RESULT .cloudmule-out/node-version.txt"
