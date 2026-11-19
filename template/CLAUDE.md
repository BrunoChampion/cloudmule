# cloudmule notes for this project

Notes for agents about running this project's heavy work with cloudmule (the `cloudmule` skill has the general
rules). Keep this file up to date when jobs change.

## Jobs (`jobs/`)

| Job | What it does | Results (`CLOUDMULE_RESULT`) |
|---|---|---|
| `example` | prints the server's Node version | `.cloudmule-out/node-version.txt` |

## Settings (`config.sh`)

- What is never uploaded and why; which files are seeds (generated on the server).
- How dependencies are installed and what check confirms it.
- System tools in `server-setup.sh`, if any, and why.

## GPU work (RunPod), if the project has any

- **Self-test (`GPU_SELFTEST` in `config.sh`)**: write one for any project whose output is pictures. `GPU_OK` only says
  the GPU drew *something* without losing its context; only this project knows what a correct frame looks like.
  Pattern: render 3–4 frames on the pod and compare them (SSIM ≥ 0.95, `ffmpeg … ssim`) with the same frames rendered
  locally; keep the references in `.cloudmule/files/` (uploaded, `$CLOUDMULE_FILES`) or in the project.
- **Parallel tasks (slots)**: the number of tasks that ran at once on one pod, with the `GPU_USE` line that measured
  it, so the next session starts there.

## Reference numbers and known problems

- Real durations, upload/download sizes, server type used, errors already solved.
