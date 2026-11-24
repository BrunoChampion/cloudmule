# Spec 0006: excludes from the environment that arrive, an upload that fits the pod, a cap raised for one day

Status: to implement. Written on 2026-11-19 by the Short Form session that hit the problems below, at the owner's
request, for an agent that works inside this repository. Vocabulary: `CONTEXT.md`. Related: spec 0004 (RunPod),
spec 0005 and its follow-ups, and the Short Form project's `docs/cloudmule-runpod-aprendizajes.md` (incidents 4 and 5).

## What happened (incident 5 of Short Form, 2026-11-19, episode 007-columbus)

**The command:** `ONESHOT_EXCLUDE="$(node tools/pod-excludes.mjs episodes/007-columbus)" cloudmule gpu short-form --approved --gpu "NVIDIA A40" --max-minutes 15 render-short episodes/007-columbus columbus 32`.

**The excludes never arrived.** The list leaves out every other episode, `docs/` and `assets/music/long-theme.mp3`.
The pod passed the WebGL check and printed `396 file(s) to upload (94.4 MB)`, including `docs/` and
`long-theme.mp3`.

**The upload could not fit.** The owner's home upload measured **70 KB/s**: 94 MB needs ~22 min, more than the
pod's 15-min cap. The guard deleted the pod mid-upload (`Connection … closed by remote host`, `Broken pipe`).
`PHASES budget=3 prep=2 catalog=1 create=3 ssh=192 modules=3 webgl=25 delete=0`. Cost ~0.14 USD, no render.
- This time cloudmule **did exit 2**. In incident 4 (003-snow, the same day) it exited 0.

**The cause is in `bin/lib.sh`, `load_project`:**
- line 135 resets `ONESHOT_EXCLUDE=""` (with the other per-project settings);
- line 141 then sources the project's `config.sh`.

So a value given in the environment is lost before the project config can use it. A project config that writes
`ONESHOT_EXCLUDE="… ${ONESHOT_EXCLUDE:-}"` (Short Form's did) still gets an empty value.
- The code has been like this since the first commit (`f58dd0c`).
- `template/config.sh` line 55 (`ONESHOT_EXCLUDE=""`) would wipe it too.
- `CLAUDE.md` (line ~205) and Short Form's guides told agents to pass it from the environment, which never worked.

**Workaround applied in Short Form:** its `config.sh` now adds `${SF_POD_EXCLUDE:-}`, a variable cloudmule does not
reset. The retry uploaded **4.5 MB in 105 s** and rendered (11.8 min of pod, ~0.116 USD). Two more renders the same
evening uploaded in 7–11 s.

**The day cap had no clean override.** After two pods the day's spend was 1.99 USD against the 2.00 USD default
`RUNPOD_MAX_USD_PER_DAY`. The next launch refused with `DAILY_CAP_REACHED` (correct). The owner then raised that
day's cap to 3 USD in chat.
- The only way to apply it was to append `RUNPOD_MAX_USD_PER_DAY=3.00` to `cloudmule/.env` (where the API keys live)
  and remove the line by hand after each render. That happened three times.
- `lib.sh` lines 9–11 deliberately refuse caps from the environment ("nobody raises them for one command"). That
  principle is right, but there is no owner-facing, time-limited way either.

## Changes

### 1 · `ONESHOT_EXCLUDE` from the environment is added, never lost (must)

- **In `bin/lib.sh` `load_project`, before line 135:** save the environment's value
  (`local env_oneshot="${ONESHOT_EXCLUDE:-}"`).
- **After sourcing `config.sh`** (and again after the re-read for `NEEDS_TARGET`), add it:
  `ONESHOT_EXCLUDE="${ONESHOT_EXCLUDE:-} $env_oneshot"`. The project's own excludes and the run's excludes add up;
  neither replaces the other.
- **Print it** when it is not empty, right before `== Syncing … ==`, so a run log shows what was excluded:
  `ONESHOT_EXCLUDE from the environment: N pattern(s)`. Print the count, and the first ~6 patterns, never values that
  could be secrets (they are paths, but keep it short).
- **`template/config.sh`:**
  - change line 55 to `ONESHOT_EXCLUDE=""   # this project's own; a run can add more from the environment` and keep it
    harmless (the add-up happens in `load_project`);
  - update the comment: "Extra excludes only for `cloudmule oneshot` and `cloudmule gpu`. A single run can add more
    from the environment: `ONESHOT_EXCLUDE="a b" cloudmule gpu …`".
- **Docs:** `CLAUDE.md` (the gpu flow, line ~205), `README.md` and `plugin/skills/cloudmule/SKILL.md` say that the
  environment's value is added to the project's.
- **Test** (`tests/run.sh`, with `fake-ssh` / `fake-runpod`): a project whose `config.sh` sets
  `ONESHOT_EXCLUDE="a"` and a run with `ONESHOT_EXCLUDE="b"` must exclude both. A file under `a/` and one under `b/`
  stay off the upload plan, which `sync-plan` prints. Also test the case where `config.sh` sets nothing.
- **Compatibility:** Short Form's `SF_POD_EXCLUDE` keeps working; once this ships, that project can go back to
  `ONESHOT_EXCLUDE` (its owner decides).

### 2 · An upload that cannot fit stops before it starts, and a slow one stops early (must)

The cost of incidents 4 and 5 was a pod billing while a hopeless upload ran into the guard.

- **a. Size limit per project.** A new setting in `config.sh`, `GPU_MAX_UPLOAD_MB` (empty = no limit). The template
  suggests 50.
  - After `sync-plan` prints `N file(s) to upload (X MB)`, if X > the limit, stop with
    `UPLOAD_TOO_BIG: X MB to upload, the project allows Y MB (GPU_MAX_UPLOAD_MB)`.
  - Also print the five biggest top-level folders in the plan, with their MB, so the cause is obvious (for 007:
    `episodes/L001-vaccine 39.5 MB`, `assets/music 14.2 MB`, `docs …`).
  - Delete the pod and exit ≠ 0. `sync-plan` already has the per-file sizes, so the folder totals cost nothing.
- **b. Upload speed and ETA.** The tar stream of `sync_tree` goes through a small counter (in `tools.py`, or `pv` if
  the module provides it). Every 10 s it prints `upload: X/Y MB, Z KB/s, ETA m:ss`.
  - The bytes and the wall time are enough; no extra network calls.
  - After 20 s, if `ETA` passes `CLOUDMULE_DEADLINE − now − margin`, stop the upload and exit ≠ 0 with
    `UPLOAD_TOO_SLOW: Y MB at Z KB/s needs ~T min, the pod has ~R min left`. The margin is the job's minimum time,
    default 4 min, `GPU_JOB_MIN_MINUTES` in `config.sh`. Then delete the pod.
  - This is follow-up item 3 of incident 4 in Short Form's learnings, now with a measured case: 94 MB at 70 KB/s
    against 11 min left.
- **c. Exit codes and usage.** Any end of the upload that is not success must exit ≠ 0 and write the reason in
  `usage.tsv`:
  - `UPLOAD_TOO_BIG` or `UPLOAD_TOO_SLOW`;
  - `POD_CAP_REACHED` when the guard deleted the pod (today the run shows `Broken pipe`).

  Incident 4 exited 0; incident 5 exited 2 without a named reason. Add a test that simulates the pod vanishing
  mid-upload with `fake-ssh` and checks the exit code and the usage line.
- **Phases:** add `upload_mb` and `upload_kbps` to the `PHASES` line (e.g. `sync=105(4.5MB,44KB/s)`), so
  `cloudmule usage --phases` shows upload speed over time.

### 3 · Raise the day cap for today only, as an owner action (should)

- **New command:** `cloudmule caps --day <usd> [--yes]`. It writes `logs/caps-override.json` as
  `{ "date": "YYYY-MM-DD", "day_usd": 3.0, "set_at": "…", "by": "owner" }`, using the computer's local date, the
  same one `usage`'s "today" uses (check `tools.py` limits and `usage`; they must agree).
- **When the limits are computed** (`tools.py`, the `day-left` that `lib.sh` passes), use `max(.env cap, override)`
  only when the override's date is today. On another date it is ignored, and `caps` or `status` deletes the stale file.
- **Limits:**
  - at most 5× the `.env` cap, or a hard ceiling of 10 USD;
  - never above `RUNPOD_MAX_USD_PER_MONTH`'s remaining amount;
  - `--yes` is required when the command does not run on a terminal (an agent). The agent may run it only with the
    owner's explicit approval for that day, the same rule as creating pods.
- **Visibility:**
  - `cloudmule status` and `cloudmule usage` print `today's cap: 3.00 USD (raised from 2.00 for 2026-11-19 only)`;
  - every `gpu` launch prints the cap it used.
- **Keep the principle:** caps still never come from the environment or from a single command's flags. This is a
  separate, dated, visible owner action that expires by itself.
- **Docs:** `CLAUDE.md` (RunPod caps section), `README.md` and the plugin skill.
- **Test:** an override for today lets a launch through that would otherwise get `DAILY_CAP_REACHED`; an override
  dated yesterday does not.

### 4 · Small things seen on the way (could)

- **A WebGL check before a hopeless upload.** It is cheap, but with 2b the upload's ETA would also be known earlier.
  Consider running the ETA probe (the first 20 s of upload) before `ensure_modules`/the WebGL check. Saving this
  money matters most on slow home connections.
- **`render-short` progress in the run log.** The local log only shows the job's output after the pull, so on a long
  render the operator sees nothing for 5 min. Optional: stream the job's last line every 30 s.

## Acceptance

- `tests/run.sh` passes with the new tests (1, 2c, 3; 2a/2b with a fake slow pipe).
- A real run of Short Form's Short with `ONESHOT_EXCLUDE="$(node tools/pod-excludes.mjs <ep>)"` (without
  `SF_POD_EXCLUDE`) uploads ~5 MB, and the log shows the environment's patterns.
- With `GPU_MAX_UPLOAD_MB=20` in Short Form's `config.sh` and no excludes, the run stops with `UPLOAD_TOO_BIG` before
  uploading, exit ≠ 0, and a `usage.tsv` line. The pod is deleted within a minute (cost < 0.03 USD).
- `cloudmule caps --day 3.00 --yes`, then `status`, shows the raised cap; the next day it is gone without anyone
  touching `.env`.

## Out of scope

- Moving Short Form back from `SF_POD_EXCLUDE` to `ONESHOT_EXCLUDE`: that project's decision after this ships.
- Per-job include lists (a job declaring what it needs, follow-up item 1 of incident 4): still a good idea, but a
  bigger change. With 1 and 2 shipped, the excludes are reliable and a mistake is caught before it costs a pod.
